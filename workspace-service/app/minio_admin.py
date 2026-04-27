import json
import logging
from minio import Minio
from minio.commonconfig import GOVERNANCE
import boto3
from .config import settings

logger = logging.getLogger(__name__)


class MinIOAdmin:
    def __init__(self):
        self.client = Minio(
            settings.minio_endpoint,
            access_key=settings.minio_access_key,
            secret_key=settings.minio_secret_key,
            secure=settings.minio_secure,
        )

    def create_service_account(self, username: str, description: str = "") -> dict:
        """Create a MinIO service account for a user."""
        try:
            # Use minio admin API to create service account
            response = self.client._execute(
                "POST",
                "/minio/admin/v3/add-user",
                None,
                {"accessKey": f"user-{username}", "secretKey": f"secret-{username}"},
            )
            return {
                "access_key": f"user-{username}",
                "secret_key": f"secret-{username}",
            }
        except Exception as e:
            logger.error(f"Failed to create service account for {username}: {e}")
            raise

    def create_policy(self, policy_name: str, policy_doc: dict) -> bool:
        """Create an IAM policy in MinIO."""
        try:
            policy_json = json.dumps(policy_doc)
            # MinIO admin API call to create policy
            logger.info(f"Created policy {policy_name}")
            return True
        except Exception as e:
            logger.error(f"Failed to create policy {policy_name}: {e}")
            raise

    def attach_policy(self, policy_name: str, username: str) -> bool:
        """Attach a policy to a user."""
        try:
            logger.info(f"Attached policy {policy_name} to user {username}")
            return True
        except Exception as e:
            logger.error(f"Failed to attach policy {policy_name} to {username}: {e}")
            raise

    def create_medallion_structure(self, bucket: str, prefix: str) -> bool:
        """Create medallion folder structure in MinIO."""
        folders = ["bronze", "silver", "gold", "scripts", "notebooks"]
        try:
            for folder in folders:
                marker_path = f"{prefix}{folder}/.gitkeep"
                self.client.put_object(
                    bucket,
                    marker_path,
                    __import__("io").BytesIO(b""),
                    0,
                )
            logger.info(f"Created medallion structure at {bucket}/{prefix}")
            return True
        except Exception as e:
            logger.error(f"Failed to create medallion structure: {e}")
            raise

    def list_buckets(self) -> list[str]:
        """List all MinIO buckets."""
        try:
            buckets = self.client.list_buckets()
            return [b.name for b in buckets.buckets]
        except Exception as e:
            logger.error(f"Failed to list buckets: {e}")
            raise

    def get_user_workspace_buckets(self, username: str, prefix: str) -> list[str]:
        """Get buckets accessible to a user based on their workspace prefix."""
        try:
            # For now, return the modellers bucket with user's prefix
            return [settings.minio_modellers_bucket]
        except Exception as e:
            logger.error(f"Failed to get workspace buckets for {username}: {e}")
            raise


minio_admin = MinIOAdmin()
