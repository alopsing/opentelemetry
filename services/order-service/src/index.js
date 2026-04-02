'use strict';

require('./tracing');

const express = require('express');
const axios = require('axios');
const winston = require('winston');
const { trace, context, metrics } = require('@opentelemetry/api');

const app = express();
app.use(express.json());

const INVENTORY_SERVICE_URL = process.env.INVENTORY_SERVICE_URL || 'http://localhost:3002';

// Winston logger that injects traceId and spanId from active span context
const logger = winston.createLogger({
  level: 'info',
  format: winston.format.combine(
    winston.format.timestamp(),
    winston.format.printf(({ level, message, timestamp, ...meta }) => {
      const activeSpan = trace.getActiveSpan();
      let traceId = '';
      let spanId = '';
      if (activeSpan) {
        const spanContext = activeSpan.spanContext();
        traceId = spanContext.traceId;
        spanId = spanContext.spanId;
      }
      return JSON.stringify({ timestamp, level, message, traceId, spanId, ...meta });
    })
  ),
  transports: [new winston.transports.Console()],
});

// Custom metrics
const meter = metrics.getMeter('order-service', '1.0.0');

const ordersCounter = meter.createCounter('order_service_orders_total', {
  description: 'Total number of orders processed by the order service',
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
  res.json({ status: 'ok', service: 'order-service' });
});

app.post('/order', async (req, res) => {
  const tracer = trace.getTracer('order-service', '1.0.0');
  const span = tracer.startSpan('validate-order');

  await context.with(trace.setSpan(context.active(), span), async () => {
    try {
      const { orderId, userId, itemId } = req.body;

      span.setAttributes({
        'order.id': orderId || 'unknown',
        'user.id': userId || 'unknown',
        'item.id': itemId || 'unknown',
      });

      logger.info('Validating order', { orderId, userId, itemId });

      // Validate required fields
      if (!orderId) {
        span.setAttributes({ 'validation.status': 'failed', 'validation.reason': 'missing orderId' });
        res.status(400).json({ error: 'orderId is required' });
        return;
      }

      // Call inventory service to check stock
      const inventoryResponse = await axios.get(`${INVENTORY_SERVICE_URL}/inventory/check`, {
        params: { itemId: itemId || 'item-001' },
      });

      const { available, quantity } = inventoryResponse.data;

      span.setAttributes({
        'inventory.available': available,
        'inventory.quantity': quantity,
        'order.status': available ? 'confirmed' : 'rejected',
      });

      if (!available) {
        ordersCounter.add(1, { status: 'rejected', reason: 'out_of_stock' });
        logger.warn('Order rejected — item not available', { orderId, itemId });
        res.status(409).json({ error: 'Item not available', orderId, itemId });
        return;
      }

      ordersCounter.add(1, { status: 'confirmed' });
      logger.info('Order validated and confirmed', { orderId, itemId, quantity });

      res.json({
        orderId,
        status: 'confirmed',
        itemId,
        quantity,
        timestamp: new Date().toISOString(),
      });
    } catch (err) {
      span.recordException(err);
      span.setAttributes({ 'order.status': 'error', 'error.message': err.message });
      ordersCounter.add(1, { status: 'error' });
      logger.error('Order processing failed', { error: err.message });
      res.status(500).json({ error: 'Order processing failed', details: err.message });
    } finally {
      span.end();
    }
  });
});

const PORT = process.env.PORT || 3001;
app.listen(PORT, () => {
  logger.info(`order-service listening on port ${PORT}`);
});

module.exports = app;
