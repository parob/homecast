"""
Utilities for encoding/decoding share URL hashes.

Share URL format: https://homecast.cloud/s/{hash}
Hash format: {type_code}{id_part}{signature}
- type_code: single char (c=collection, r=room, g=group, h=home, a=accessory)
- id_part: first 8 chars of UUID (without hyphens)
- signature: 4 char HMAC signature for verification
"""

import hmac
import hashlib
from typing import Tuple, Optional
from uuid import UUID

from homecast import config


# Entity type to code mapping
TYPE_TO_CODE = {
    "collection": "c",
    "collection_group": "G",  # Capital G for collection groups
    "room": "r",
    "room_group": "R",  # Capital R for room groups
    "group": "g",
    "home": "h",
    "accessory": "a",
}

CODE_TO_TYPE = {v: k for k, v in TYPE_TO_CODE.items()}


def encode_share_hash(entity_type: str, entity_id: UUID) -> str:
    """
    Encode an entity type and ID into a share hash.

    Args:
        entity_type: Type of entity (collection, room, group, home, accessory)
        entity_id: UUID of the entity

    Returns:
        Hash string for the share URL (e.g., "c86974af0ab3")

    Raises:
        ValueError: If entity_type is invalid
    """
    if entity_type not in TYPE_TO_CODE:
        raise ValueError(f"Invalid entity type: {entity_type}")

    type_code = TYPE_TO_CODE[entity_type]

    # First 8 chars of UUID without hyphens
    id_part = str(entity_id).replace("-", "")[:8]

    # Generate HMAC signature (4 chars = 2 bytes hex)
    secret = config.SHARE_SECRET_KEY.encode()
    message = f"{entity_type}:{entity_id}".encode()
    sig = hmac.new(secret, message, hashlib.sha256).digest()[:2].hex()

    return f"{type_code}{id_part}{sig}"


def decode_share_hash(share_hash: str) -> Tuple[str, str, str]:
    """
    Decode a share hash into entity type and partial ID.

    Args:
        share_hash: The hash from the share URL

    Returns:
        Tuple of (entity_type, id_prefix, signature)
        - entity_type: Type of entity
        - id_prefix: First 8 chars of UUID (for DB lookup)
        - signature: The HMAC signature to verify

    Raises:
        ValueError: If hash format is invalid
    """
    if len(share_hash) < 13:  # 1 (type) + 8 (id) + 4 (sig)
        raise ValueError("Invalid share hash: too short")

    type_code = share_hash[0]
    if type_code not in CODE_TO_TYPE:
        raise ValueError(f"Invalid share hash: unknown type code '{type_code}'")

    entity_type = CODE_TO_TYPE[type_code]
    id_prefix = share_hash[1:9]
    signature = share_hash[9:13]

    return (entity_type, id_prefix, signature)


def verify_share_hash(share_hash: str, entity_type: str, entity_id: UUID) -> bool:
    """
    Verify that a share hash matches the expected entity.

    Args:
        share_hash: The hash from the share URL
        entity_type: Expected entity type
        entity_id: Full entity UUID

    Returns:
        True if the hash is valid for this entity
    """
    try:
        decoded_type, id_prefix, signature = decode_share_hash(share_hash)

        # Check type matches
        if decoded_type != entity_type:
            return False

        # Check ID prefix matches
        full_id = str(entity_id).replace("-", "")
        if not full_id.startswith(id_prefix):
            return False

        # Verify HMAC signature
        secret = config.SHARE_SECRET_KEY.encode()
        message = f"{entity_type}:{entity_id}".encode()
        expected_sig = hmac.new(secret, message, hashlib.sha256).digest()[:2].hex()

        return hmac.compare_digest(signature, expected_sig)

    except (ValueError, AttributeError):
        return False


def get_entity_type_from_hash(share_hash: str) -> Optional[str]:
    """
    Extract the entity type from a share hash without full decoding.

    Args:
        share_hash: The hash from the share URL

    Returns:
        Entity type string or None if invalid
    """
    if not share_hash or len(share_hash) < 1:
        return None

    type_code = share_hash[0]
    return CODE_TO_TYPE.get(type_code)
