'use strict';

require('./tracing');

const express = require('express');
const axios = require('axios');
const winston = require('winston');
const { trace, context, metrics, SpanStatusCode } = require('@opentelemetry/api');
const { OpenTelemetryTransportV3 } = require('@opentelemetry/winston-transport');

const app = express();
app.use(express.json());

const PRODUCT_SERVICE_URL = process.env.PRODUCT_SERVICE_URL || 'http://product-service:3003';

// Winston logger — OTel transport sends logs via OTLP; Console transport for stdout
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

// Custom metrics
const meter = metrics.getMeter('inventory-service', '1.0.0');

const checksCounter = meter.createCounter('inventory_service_checks_total', {
  description: 'Total number of inventory checks performed',
});

// Stock-level gauge is now reported by product-service (backed by PostgreSQL).
// inventory-service only tracks check counts and latency.
const checkLatencyHistogram = meter.createHistogram('inventory_service_check_duration_ms', {
  description: 'Duration of inventory checks (including product-service call) in milliseconds',
  unit: 'ms',
});

// Middleware to log each request
app.use((req, res, next) => {
  const startTime = Date.now();
  res.on('finish', () => {
    const duration = Date.now() - startTime;
    logger.info('Request processed', {
      method: req.method,
      path: req.path,
      statusCode: res.statusCode,
      durationMs: duration,
    });
  });
  next();
});

app.get('/health', (req, res) => {
  res.json({ status: 'ok', service: 'inventory-service' });
});

app.get('/inventory/check', async (req, res) => {
  const tracer = trace.getTracer('inventory-service', '1.0.0');
  const span = tracer.startSpan('check-stock');
  const checkStart = Date.now();

  return context.with(trace.setSpan(context.active(), span), async () => {
    const itemId = req.query.itemId || 'item-001';
    span.setAttributes({ 'inventory.item_id': itemId });

    try {
      // Delegate to product-service — axios auto-instrumentation propagates the
      // W3C traceparent header so this call appears as a child span in Jaeger.
      const response = await axios.get(`${PRODUCT_SERVICE_URL}/products/${itemId}`);
      const product = response.data;
      const available = product.available;

      span.setAttributes({
        'inventory.found': true,
        'inventory.available': available,
        'inventory.quantity': product.stockQuantity,
        'inventory.item_name': product.name,
        'inventory.source': 'product-service',
      });

      checksCounter.add(1, { item_id: itemId, result: available ? 'available' : 'out_of_stock' });
      checkLatencyHistogram.record(Date.now() - checkStart, { item_id: itemId });

      logger.info('Inventory check completed via product-service', {
        itemId,
        itemName: product.name,
        quantity: product.stockQuantity,
        available,
      });

      res.json({
        itemId,
        itemName: product.name,
        available,
        quantity: product.stockQuantity,
        checkedAt: new Date().toISOString(),
      });

    } catch (err) {
      span.recordException(err);
      span.setStatus({ code: SpanStatusCode.ERROR, message: err.message });
      checkLatencyHistogram.record(Date.now() - checkStart, { item_id: itemId });

      if (err.response && err.response.status === 404) {
        checksCounter.add(1, { item_id: itemId, result: 'not_found' });
        logger.warn('Item not found in product-service', { itemId });
        res.status(404).json({ error: 'Item not found', itemId });
      } else {
        checksCounter.add(1, { item_id: itemId, result: 'error' });
        logger.error('Inventory check failed', { itemId, error: err.message });
        res.status(500).json({ error: 'Inventory check failed', details: err.message });
      }
    } finally {
      span.end();
    }
  });
});

const PORT = process.env.PORT || 3002;
app.listen(PORT, () => {
  logger.info(`inventory-service listening on port ${PORT}`);
});

module.exports = app;
