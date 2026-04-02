'use strict';

require('./tracing');

const express = require('express');
const axios = require('axios');
const winston = require('winston');
const { trace, context, metrics } = require('@opentelemetry/api');
const { OpenTelemetryTransportV3 } = require('@opentelemetry/winston-transport');

const app = express();
app.use(express.json());

const ORDER_SERVICE_URL = process.env.ORDER_SERVICE_URL || 'http://localhost:3001';

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
const meter = metrics.getMeter('api-gateway', '1.0.0');

const requestCounter = meter.createCounter('api_gateway_requests_total', {
  description: 'Total number of requests received by the API gateway',
});

const requestDuration = meter.createHistogram('api_gateway_request_duration_ms', {
  description: 'Duration of API gateway requests in milliseconds',
  unit: 'ms',
});

// Middleware to record metrics and log each request
app.use((req, res, next) => {
  const startTime = Date.now();
  res.on('finish', () => {
    const duration = Date.now() - startTime;
    const labels = { method: req.method, route: req.path, status: String(res.statusCode) };
    requestCounter.add(1, labels);
    requestDuration.record(duration, labels);
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
  res.json({ status: 'ok', service: 'api-gateway' });
});

app.post('/order', async (req, res) => {
  const tracer = trace.getTracer('api-gateway', '1.0.0');
  const span = tracer.startSpan('process-order');

  await context.with(trace.setSpan(context.active(), span), async () => {
    try {
      const orderId = `order-${Date.now()}`;
      const userId = req.body.userId || 'anonymous';
      const itemId = req.body.itemId || 'item-001';

      span.setAttributes({
        'order.id': orderId,
        'user.id': userId,
        'item.id': itemId,
      });

      logger.info('Processing new order', { orderId, userId, itemId });

      // Propagate trace context via HTTP headers automatically (handled by auto-instrumentation)
      const response = await axios.post(`${ORDER_SERVICE_URL}/order`, {
        orderId,
        userId,
        itemId,
      });

      span.setAttributes({ 'order.status': 'success' });
      logger.info('Order processed successfully', { orderId, orderResult: response.data });

      res.json({
        orderId,
        status: 'created',
        orderDetails: response.data,
      });
    } catch (err) {
      span.recordException(err);
      span.setAttributes({ 'order.status': 'error', 'error.message': err.message });
      logger.error('Failed to process order', { error: err.message });
      res.status(500).json({ error: 'Failed to process order', details: err.message });
    } finally {
      span.end();
    }
  });
});

const PORT = process.env.PORT || 3000;
app.listen(PORT, () => {
  logger.info(`api-gateway listening on port ${PORT}`);
});

module.exports = app;
