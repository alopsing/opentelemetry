'use strict';

require('./tracing');

const express = require('express');
const winston = require('winston');
const { trace, context, metrics } = require('@opentelemetry/api');
const { OpenTelemetryTransportV3 } = require('@opentelemetry/winston-transport');

const app = express();
app.use(express.json());

// Simulated inventory data store
const inventory = {
  'item-001': { quantity: 42, name: 'Widget A' },
  'item-002': { quantity: 0, name: 'Widget B' },
  'item-003': { quantity: 15, name: 'Widget C' },
  'item-004': { quantity: 7, name: 'Widget D' },
};

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

const stockGauge = meter.createObservableGauge('inventory_service_stock_level', {
  description: 'Current stock level per item',
});

stockGauge.addCallback((observableResult) => {
  for (const [itemId, item] of Object.entries(inventory)) {
    observableResult.observe(item.quantity, { item_id: itemId, item_name: item.name });
  }
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

app.get('/inventory/check', (req, res) => {
  const tracer = trace.getTracer('inventory-service', '1.0.0');
  const span = tracer.startSpan('check-stock');

  context.with(trace.setSpan(context.active(), span), () => {
    try {
      const itemId = req.query.itemId || 'item-001';
      const item = inventory[itemId];

      span.setAttributes({
        'inventory.item_id': itemId,
      });

      if (!item) {
        span.setAttributes({
          'inventory.found': false,
          'inventory.available': false,
        });
        checksCounter.add(1, { item_id: itemId, result: 'not_found' });
        logger.warn('Item not found in inventory', { itemId });
        res.status(404).json({ error: 'Item not found', itemId });
        return;
      }

      const available = item.quantity > 0;

      span.setAttributes({
        'inventory.found': true,
        'inventory.available': available,
        'inventory.quantity': item.quantity,
        'inventory.item_name': item.name,
      });

      checksCounter.add(1, { item_id: itemId, result: available ? 'available' : 'out_of_stock' });

      logger.info('Inventory check completed', {
        itemId,
        itemName: item.name,
        quantity: item.quantity,
        available,
      });

      res.json({
        itemId,
        itemName: item.name,
        available,
        quantity: item.quantity,
        checkedAt: new Date().toISOString(),
      });
    } catch (err) {
      span.recordException(err);
      checksCounter.add(1, { item_id: req.query.itemId || 'unknown', result: 'error' });
      logger.error('Inventory check failed', { error: err.message });
      res.status(500).json({ error: 'Inventory check failed', details: err.message });
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
