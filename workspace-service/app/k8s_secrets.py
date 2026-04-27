import logging
import base64
from kubernetes import client, config as k8s_config, watch
from .config import settings

logger = logging.getLogger(__name__)


class K8sSecretsManager:
    def __init__(self):
        try:
            if settings.kubernetes_in_cluster:
                k8s_config.load_incluster_config()
            else:
                k8s_config.load_kube_config()
        except Exception as e:
            logger.warning(f"Failed to load k8s config: {e}")

        self.v1 = client.CoreV1Api()
        self.namespace = settings.kubernetes_namespace

    def write_minio_secret(
        self, username: str, access_key: str, secret_key: str
    ) -> str:
        """Create a Kubernetes secret with MinIO credentials."""
        secret_name = f"minio-user-{username}-creds"

        secret_data = {
            "access-key": base64.b64encode(access_key.encode()).decode(),
            "secret-key": base64.b64encode(secret_key.encode()).decode(),
        }

        secret = client.V1Secret(
            api_version="v1",
            kind="Secret",
            metadata=client.V1ObjectMeta(
                name=secret_name, namespace=self.namespace, labels={"user": username}
            ),
            type="Opaque",
            data=secret_data,
        )

        try:
            self.v1.create_namespaced_secret(self.namespace, secret)
            logger.info(f"Created MinIO secret {secret_name}")
            return secret_name
        except client.exceptions.ApiException as e:
            if e.status == 409:  # Already exists
                logger.info(f"MinIO secret {secret_name} already exists")
                return secret_name
            logger.error(f"Failed to create MinIO secret: {e}")
            raise

    def write_git_secret(
        self,
        username: str,
        credential_type: str,
        credential_value: str,
    ) -> str:
        """Create a Kubernetes secret with git credentials."""
        secret_name = f"git-creds-{username}"

        if credential_type == "https_token":
            secret_data = {
                "git-credentials": base64.b64encode(
                    f"https://{credential_value}".encode()
                ).decode()
            }
        elif credential_type == "ssh_key":
            secret_data = {
                "id_rsa": base64.b64encode(credential_value.encode()).decode()
            }
        else:
            raise ValueError(f"Unsupported credential type: {credential_type}")

        secret = client.V1Secret(
            api_version="v1",
            kind="Secret",
            metadata=client.V1ObjectMeta(
                name=secret_name, namespace=self.namespace, labels={"user": username}
            ),
            type="Opaque",
            data=secret_data,
        )

        try:
            self.v1.create_namespaced_secret(self.namespace, secret)
            logger.info(f"Created git secret {secret_name}")
            return secret_name
        except client.exceptions.ApiException as e:
            if e.status == 409:  # Already exists
                logger.info(f"Git secret {secret_name} already exists")
                return secret_name
            logger.error(f"Failed to create git secret: {e}")
            raise

    def read_secret(self, secret_name: str) -> dict:
        """Read a Kubernetes secret."""
        try:
            secret = self.v1.read_namespaced_secret(secret_name, self.namespace)
            return secret.data
        except client.exceptions.ApiException as e:
            logger.error(f"Failed to read secret {secret_name}: {e}")
            raise

    def delete_secret(self, secret_name: str) -> bool:
        """Delete a Kubernetes secret."""
        try:
            self.v1.delete_namespaced_secret(secret_name, self.namespace)
            logger.info(f"Deleted secret {secret_name}")
            return True
        except client.exceptions.ApiException as e:
            if e.status == 404:
                logger.warning(f"Secret {secret_name} not found")
                return False
            logger.error(f"Failed to delete secret {secret_name}: {e}")
            raise

    def secret_exists(self, secret_name: str) -> bool:
        """Check if a secret exists."""
        try:
            self.v1.read_namespaced_secret(secret_name, self.namespace)
            return True
        except client.exceptions.ApiException as e:
            if e.status == 404:
                return False
            logger.error(f"Error checking secret existence: {e}")
            raise


secrets_manager = K8sSecretsManager()
