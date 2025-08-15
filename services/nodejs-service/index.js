const express = require('express');
const cors = require('cors');
const { Pool } = require('pg');
const promClient = require('prom-client');
const winston = require('winston');
const os = require('os');

// Configure logger
const logger = winston.createLogger({
    level: 'info',
    format: winston.format.json(),
    transports: [
        new winston.transports.Console({
            format: winston.format.simple()
        })
    ]
});

// Initialize Express app
const app = express();
app.use(cors());
app.use(express.json());

// Prometheus metrics
const register = new promClient.Registry();
promClient.collectDefaultMetrics({ register });

const httpRequestDuration = new promClient.Histogram({
    name: 'http_request_duration_seconds',
    help: 'Duration of HTTP requests in seconds',
    labelNames: ['method', 'route', 'status'],
    registers: [register]
});

const statusRequests = new promClient.Counter({
    name: 'status_requests_total',
    help: 'Total number of status requests',
    registers: [register]
});

// Database configuration
const pool = new Pool({
    host: process.env.DB_HOST || 'postgres-service',
    port: process.env.DB_PORT || 5432,
    database: process.env.DB_NAME || 'microservices',
    user: process.env.DB_USER || 'admin',
    password: process.env.DB_PASSWORD || 'admin123',
    max: 20,
    idleTimeoutMillis: 30000,
    connectionTimeoutMillis: 2000,
});

// Initialize database
async function initDatabase() {
    try {
        const client = await pool.connect();
        await client.query(`
            CREATE TABLE IF NOT EXISTS service_logs (
                id SERIAL PRIMARY KEY,
                service VARCHAR(50),
                message TEXT,
                level VARCHAR(20),
                timestamp TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                metadata JSONB
            )
        `);
        client.release();
        logger.info('Database initialized successfully');
    } catch (error) {
        logger.error('Database initialization failed:', error);
    }
}

// Middleware to track request duration
app.use((req, res, next) => {
    const start = Date.now();
    res.on('finish', () => {
        const duration = (Date.now() - start) / 1000;
        httpRequestDuration.labels(req.method, req.route?.path || req.path, res.statusCode).observe(duration);
    });
    next();
});

// Root endpoint
app.get('/', (req, res) => {
    res.json({
        message: 'Node.js Service API',
        version: '1.0.0',
        endpoints: ['/status', '/api/logs', '/api/log', '/metrics']
    });
});

// Status endpoint
app.get('/status', async (req, res) => {
    statusRequests.inc();
    const hostname = os.hostname();
    
    let dbStatus = 'unknown';
    try {
        const client = await pool.connect();
        await client.query('SELECT 1');
        client.release();
        dbStatus = 'connected';
        
        // Log status check
        await pool.query(
            'INSERT INTO service_logs (service, message, level, metadata) VALUES ($1, $2, $3, $4)',
            ['nodejs-service', 'Status check performed', 'info', JSON.stringify({ hostname })]
        );
    } catch (error) {
        dbStatus = 'disconnected';
        logger.error('Database connection error:', error);
    }
    
    res.json({
        status: 'ok',
        service: 'nodejs-service',
        version: '1.0.0',
        timestamp: new Date().toISOString(),
        hostname: hostname,
        database: dbStatus,
        environment: process.env.ENVIRONMENT || 'dev',
        uptime: process.uptime()
    });
});

// Create log entry
app.post('/api/log', async (req, res) => {
    const { message, level = 'info' } = req.body;
    
    try {
        const result = await pool.query(
            'INSERT INTO service_logs (service, message, level, metadata) VALUES ($1, $2, $3, $4) RETURNING *',
            ['nodejs-service', message, level, JSON.stringify(req.body.metadata || {})]
        );
        res.json({ success: true, log: result.rows[0] });
    } catch (error) {
        logger.error('Failed to create log entry:', error);
        res.status(500).json({ error: error.message });
    }
});

// Get recent logs
app.get('/api/logs', async (req, res) => {
    const limit = parseInt(req.query.limit) || 10;
    
    try {
        const result = await pool.query(
            'SELECT * FROM service_logs ORDER BY timestamp DESC LIMIT $1',
            [limit]
        );
        res.json({ logs: result.rows });
    } catch (error) {
        logger.error('Failed to fetch logs:', error);
        res.status(500).json({ error: error.message });
    }
});

// Metrics endpoint
app.get('/metrics', async (req, res) => {
    res.set('Content-Type', register.contentType);
    res.end(await register.metrics());
});

// Health check endpoint
app.get('/health', (req, res) => {
    res.json({ status: 'healthy' });
});

// Error handling middleware
app.use((err, req, res, next) => {
    logger.error('Unhandled error:', err);
    res.status(500).json({ error: 'Internal server error' });
});

// Start server
const PORT = process.env.PORT || 3000;
const server = app.listen(PORT, '0.0.0.0', () => {
    logger.info(`Node.js service listening on port ${PORT}`);
    initDatabase();
});

// Graceful shutdown
process.on('SIGTERM', () => {
    logger.info('SIGTERM signal received: closing HTTP server');
    server.close(() => {
        pool.end(() => {
            logger.info('Database pool closed');
            process.exit(0);
        });
    });
});