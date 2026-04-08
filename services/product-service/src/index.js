'use strict';

require('./tracing');

const express = require('express');
const { Pool } = require('pg');
const winston = require('winston');
const { trace, context, metrics, SpanStatusCode } = require('@opentelemetry/api');
const { OpenTelemetryTransportV3 } = require('@opentelemetry/winston-transport');

const app = express();
app.use(express.json());

// ── Logger ──────────────────────────────────────────────────────────────────
const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.json()
  ),
  transports: [
    new winston.transports.Console(),
    new OpenTelemetryTransportV3(),
  ],
});

// ── PostgreSQL connection pool ───────────────────────────────────────────────
// PgInstrumentation auto-wraps every pool.query() with a DB span
const pool = new Pool({
  host:     process.env.DB_HOST     || 'postgres',
  port:     parseInt(process.env.DB_PORT || '5432', 10),
  database: process.env.DB_NAME     || 'products',
  user:     process.env.DB_USER     || 'otel',
  password: process.env.DB_PASSWORD || 'otel_secret',
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});

pool.on('error', (err) => {
  logger.error('Unexpected PostgreSQL pool error', { error: err.message });
});

// ── Custom metrics ───────────────────────────────────────────────────────────
const meter = metrics.getMeter('product-service', '1.0.0');

const productLookupsCounter = meter.createCounter('product_service_lookups_total', {
  description: 'Total number of product lookups performed',
});

const dbQueryDurationHistogram = meter.createHistogram('product_service_db_query_duration_ms', {
  description: 'Duration of PostgreSQL queries in milliseconds',
  unit: 'ms',
});

const stockGauge = meter.createObservableGauge('product_service_stock_level', {
  description: 'Current stock level per product (from PostgreSQL)',
});

// Refresh stock levels every 30s into an in-memory cache for the gauge
let stockCache = [];
async function refreshStockCache() {
  try {
    const result = await pool.query('SELECT product_id, stock_quantity FROM products');
    stockCache = result.rows;
  } catch (err) {
    logger.warn('Failed to refresh stock cache for gauge', { error: err.message });
  }
}
refreshStockCache();
setInterval(refreshStockCache, 30000);

stockGauge.addCallback((observableResult) => {
  for (const row of stockCache) {
    observableResult.observe(row.stock_quantity, { product_id: row.product_id });
  }
});

// ── Request logging middleware ───────────────────────────────────────────────
app.use((req, res, next) => {
  const startTime = Date.now();
  res.on('finish', () => {
    logger.info('Request processed', {
      method: req.method,
      path: req.path,
      statusCode: res.statusCode,
      durationMs: Date.now() - startTime,
    });
  });
  next();
});

// ── Health check ─────────────────────────────────────────────────────────────
app.get('/health', async (req, res) => {
  try {
    await pool.query('SELECT 1');
    res.json({ status: 'ok', service: 'product-service', db: 'connected' });
  } catch (err) {
    res.status(503).json({ status: 'error', service: 'product-service', db: 'disconnected' });
  }
});

// ── GET /products/:productId ─────────────────────────────────────────────────
// Returns product details + current stock — DB span auto-created by PgInstrumentation
app.get('/products/:productId', async (req, res) => {
  const tracer = trace.getTracer('product-service', '1.0.0');
  const span = tracer.startSpan('get-product');

  return context.with(trace.setSpan(context.active(), span), async () => {
    const { productId } = req.params;
    span.setAttributes({ 'product.id': productId });

    try {
      const queryStart = Date.now();

      // PgInstrumentation automatically creates a child DB span for this query
      // with attributes: db.system=postgresql, db.statement, net.peer.name, db.name
      const result = await pool.query(
        'SELECT product_id, name, description, category, price, stock_quantity, sku FROM products WHERE product_id = $1',
        [productId]
      );

      dbQueryDurationHistogram.record(Date.now() - queryStart, {
        query: 'select_product_by_id',
        table: 'products',
      });

      if (result.rows.length === 0) {
        productLookupsCounter.add(1, { product_id: productId, result: 'not_found' });
        span.setAttributes({ 'product.found': false });
        logger.warn('Product not found', { productId });
        res.status(404).json({ error: 'Product not found', productId });
        return;
      }

      const product = result.rows[0];
      const available = product.stock_quantity > 0;

      span.setAttributes({
        'product.found': true,
        'product.name': product.name,
        'product.category': product.category,
        'product.stock_quantity': product.stock_quantity,
        'product.available': available,
      });

      productLookupsCounter.add(1, {
        product_id: productId,
        result: available ? 'available' : 'out_of_stock',
      });

      logger.info('Product lookup completed', {
        productId,
        name: product.name,
        stockQuantity: product.stock_quantity,
        available,
      });

      res.json({
        productId: product.product_id,
        name: product.name,
        description: product.description,
        category: product.category,
        price: parseFloat(product.price),
        stockQuantity: product.stock_quantity,
        sku: product.sku,
        available,
        checkedAt: new Date().toISOString(),
      });

    } catch (err) {
      span.recordException(err);
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      productLookupsCounter.add(1, { product_id: productId, result: 'error' });
      logger.error('Product lookup failed', { productId, error: err.message });
      res.status(500).json({ error: 'Product lookup failed', details: err.message });
    } finally {
      span.end();
    }
  });
});

// ── GET /products ─────────────────────────────────────────────────────────────
// Returns all products (useful for verifying mock data)
app.get('/products', async (req, res) => {
  const tracer = trace.getTracer('product-service', '1.0.0');
  const span = tracer.startSpan('list-products');

  return context.with(trace.setSpan(context.active(), span), async () => {
    try {
      const queryStart = Date.now();
      const result = await pool.query(
        'SELECT product_id, name, category, price, stock_quantity, sku FROM products ORDER BY product_id'
      );
      dbQueryDurationHistogram.record(Date.now() - queryStart, {
        query: 'select_all_products',
        table: 'products',
      });

      span.setAttributes({ 'products.count': result.rows.length });
      logger.info('Listed all products', { count: result.rows.length });

      res.json({ products: result.rows, total: result.rows.length });
    } catch (err) {
      span.recordException(err);
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      logger.error('List products failed', { error: err.message });
      res.status(500).json({ error: 'Failed to list products', details: err.message });
    } finally {
      span.end();
    }
  });
});

// ── Graceful shutdown ────────────────────────────────────────────────────────
process.on('SIGTERM', async () => {
  logger.info('SIGTERM received, draining DB pool...');
  await pool.end();
  process.exit(0);
});

const PORT = process.env.PORT || 3003;
app.listen(PORT, () => {
  logger.info(`product-service listening on port ${PORT}`);
});

module.exports = app;
