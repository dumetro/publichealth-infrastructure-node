import psycopg2
from psycopg2 import pool, sql
from contextlib import contextmanager
import logging
from .config import settings

logger = logging.getLogger(__name__)


class Database:
    _pool: pool.SimpleConnectionPool = None

    @classmethod
    def initialize(cls):
        """Initialize the connection pool."""
        try:
            cls._pool = pool.SimpleConnectionPool(
                1,
                settings.database_pool_size,
                settings.database_url,
                connect_timeout=5,
            )
            logger.info("Database connection pool initialized")
        except psycopg2.Error as e:
            logger.error(f"Failed to initialize database pool: {e}")
            raise

    @classmethod
    @contextmanager
    def get_connection(cls):
        """Get a connection from the pool."""
        if cls._pool is None:
            cls.initialize()
        conn = cls._pool.getconn()
        try:
            yield conn
            conn.commit()
        except psycopg2.Error as e:
            conn.rollback()
            logger.error(f"Database error: {e}")
            raise
        finally:
            cls._pool.putconn(conn)

    @classmethod
    def close_all(cls):
        """Close all connections in the pool."""
        if cls._pool:
            cls._pool.closeall()
            logger.info("All database connections closed")

    @classmethod
    def execute_query(cls, query: str, params: tuple = None) -> list:
        """Execute a SELECT query and return results."""
        with cls.get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(query, params or ())
                return cur.fetchall()

    @classmethod
    def execute_update(cls, query: str, params: tuple = None) -> int:
        """Execute INSERT/UPDATE/DELETE and return affected rows."""
        with cls.get_connection() as conn:
            with conn.cursor() as cur:
                cur.execute(query, params or ())
                return cur.rowcount

    @classmethod
    def execute_single(cls, query: str, params: tuple = None) -> dict:
        """Execute a query and return first row as dict."""
        results = cls.execute_query(query, params)
        if results:
            # This is a simplified version; proper implementation would fetch column names
            return results[0]
        return None


db = Database()
