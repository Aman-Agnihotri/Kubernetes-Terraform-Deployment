from flask import Flask, jsonify, request
from flask_cors import CORS
import psycopg2
import os
import logging
from prometheus_flask_exporter import PrometheusMetrics
from datetime import datetime
import socket
import time

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = Flask(__name__)
CORS(app)

# Initialize Prometheus metrics
metrics = PrometheusMetrics(app)
metrics.info('python_service_info', 'Python service info', version='1.0.0')

# Database configuration
DB_CONFIG = {
    'host': os.environ.get('DB_HOST', 'postgres-service'),
    'port': os.environ.get('DB_PORT', '5432'),
    'database': os.environ.get('DB_NAME', 'microservices'),
    'user': os.environ.get('DB_USER', 'admin'),
    'password': os.environ.get('DB_PASSWORD', 'admin123')
}

def get_db_connection():
    """Create database connection"""
    try:
        conn = psycopg2.connect(**DB_CONFIG)
        return conn
    except Exception as e:
        logger.error(f"Database connection failed: {e}")
        return None

def init_db(retries=8, delay_sec=2):
    """Initialize required database table with retries and backoff.
    Creates health_checks if it does not exist.
    Returns True on success, False on permanent failure.
    """
    for attempt in range(1, retries + 1):
        conn = get_db_connection()
        if conn:
            try:
                cursor = conn.cursor()
                # Create health_checks table (used by Python)
                cursor.execute('''
                    CREATE TABLE IF NOT EXISTS health_checks (
                        id SERIAL PRIMARY KEY,
                        service VARCHAR(50),
                        timestamp TIMESTAMP,
                        status VARCHAR(20),
                        hostname VARCHAR(100)
                    )
                ''')
                conn.commit()
                cursor.close()
                conn.close()
                logger.info("Database initialized successfully")
                return True
            except Exception as e:
                logger.error(f"Database initialization attempt {attempt} failed: {e}")
                try:
                    conn.close()
                except Exception:
                    pass
        else:
            logger.warning(f"Database connection attempt {attempt} failed")
        if attempt < retries:
            sleep_for = delay_sec * attempt
            logger.info(f"Retrying database init in {sleep_for} seconds (attempt {attempt}/{retries})")
            time.sleep(sleep_for)
    logger.error("Database initialization failed after all retries")
    return False

@app.route('/health', methods=['GET'])
@metrics.counter('health_check_total', 'Total health check requests')
def health():
    """Health check endpoint"""
    hostname = socket.gethostname()
    timestamp = datetime.now()
    
    # Log health check to database
    conn = get_db_connection()
    if conn:
        try:
            cursor = conn.cursor()
            cursor.execute(
                "INSERT INTO health_checks (service, timestamp, status, hostname) VALUES (%s, %s, %s, %s)",
                ('python-service', timestamp, 'healthy', hostname)
            )
            conn.commit()
            cursor.close()
            conn.close()
            db_status = "connected"
        except Exception as e:
            logger.error(f"Failed to log health check: {e}")
            db_status = "error"
    else:
        db_status = "disconnected"
    
    return jsonify({
        'status': 'healthy',
        'service': 'python-service',
        'version': '1.0.0',
        'timestamp': timestamp.isoformat(),
        'hostname': hostname,
        'database': db_status,
        'environment': os.environ.get('ENVIRONMENT', 'dev')
    }), 200

@app.route('/api/data', methods=['GET'])
@metrics.counter('api_data_requests', 'Total API data requests')
def get_data():
    """Get recent health checks from database"""
    conn = get_db_connection()
    if not conn:
        return jsonify({'error': 'Database connection failed'}), 500
    
    try:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT * FROM health_checks ORDER BY timestamp DESC LIMIT 10"
        )
        rows = cursor.fetchall()
        cursor.close()
        conn.close()
        
        data = []
        for row in rows:
            data.append({
                'id': row[0],
                'service': row[1],
                'timestamp': row[2].isoformat() if row[2] else None,
                'status': row[3],
                'hostname': row[4]
            })
        
        return jsonify({'data': data}), 200
    except Exception as e:
        logger.error(f"Failed to fetch data: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/api/stats', methods=['GET'])
def get_stats():
    """Get service statistics"""
    conn = get_db_connection()
    if not conn:
        return jsonify({'error': 'Database connection failed'}), 500
    
    try:
        cursor = conn.cursor()
        cursor.execute(
            "SELECT COUNT(*), service FROM health_checks GROUP BY service"
        )
        rows = cursor.fetchall()
        cursor.close()
        conn.close()
        
        stats = {}
        for row in rows:
            stats[row[1]] = row[0]
        
        return jsonify({'stats': stats}), 200
    except Exception as e:
        logger.error(f"Failed to fetch stats: {e}")
        return jsonify({'error': str(e)}), 500

@app.route('/', methods=['GET'])
def index():
    """Root endpoint"""
    return jsonify({
        'message': 'Python Service API',
        'endpoints': ['/health', '/api/data', '/api/stats', '/metrics']
    }), 200

# Ensure DB is initialized when the module is loaded (covers gunicorn workers too)
# Block until DB initialized to guarantee required tables exist before the service starts.
# This prevents race conditions where the app starts but required tables are missing.
while not init_db(retries=8, delay_sec=3):
    logger.warning("Database not ready or migration failed; retrying in 5 seconds")
    time.sleep(5)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=False)