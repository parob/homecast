"""
Unit tests for HomeAPI handler.

Tests the HomeScopedApp routing and validation.
"""

import pytest
from unittest.mock import patch, MagicMock, AsyncMock
from starlette.testclient import TestClient
from starlette.applications import Starlette
from starlette.routing import Mount

from homecast.home_app import (
    HomeScopedApp,
    validate_home_id,
    get_home_auth_enabled,
    HOME_ID_PATTERN,
    HOME_PATH_PATTERN,
)


def create_test_app(home_app):
    """Create a Starlette app with the HomeAPI mounted at /home/."""
    return Starlette(routes=[Mount("/home/", app=home_app)])


class TestValidateHomeId:
    """Tests for home_id validation."""

    def test_valid_home_id(self):
        """Valid 8 hex character home_id should be normalized to lowercase."""
        assert validate_home_id("abcd1234") == "abcd1234"
        assert validate_home_id("ABCD1234") == "abcd1234"
        assert validate_home_id("AbCd1234") == "abcd1234"

    def test_invalid_home_id_too_short(self):
        """Home IDs shorter than 8 chars should be rejected."""
        assert validate_home_id("abc123") is None
        assert validate_home_id("") is None

    def test_invalid_home_id_too_long(self):
        """Home IDs longer than 8 chars should be rejected."""
        assert validate_home_id("abcd12345") is None
        assert validate_home_id("abcd1234abcd1234") is None

    def test_invalid_home_id_non_hex(self):
        """Home IDs with non-hex characters should be rejected."""
        assert validate_home_id("abcd123g") is None
        assert validate_home_id("abcd-123") is None
        assert validate_home_id("abcd 123") is None

    def test_none_home_id(self):
        """None home_id should be rejected."""
        assert validate_home_id(None) is None


class TestHomeIdPattern:
    """Tests for HOME_ID_PATTERN regex."""

    def test_matches_valid_hex(self):
        assert HOME_ID_PATTERN.match("abcd1234")
        assert HOME_ID_PATTERN.match("ABCD1234")
        assert HOME_ID_PATTERN.match("00000000")
        assert HOME_ID_PATTERN.match("ffffffff")

    def test_rejects_invalid(self):
        assert not HOME_ID_PATTERN.match("abcd123")  # too short
        assert not HOME_ID_PATTERN.match("abcd12345")  # too long
        assert not HOME_ID_PATTERN.match("abcd123g")  # invalid char


class TestHomePathPattern:
    """Tests for HOME_PATH_PATTERN regex."""

    def test_extracts_home_id_and_path(self):
        match = HOME_PATH_PATTERN.match("abcd1234/mcp")
        assert match
        assert match.group(1) == "abcd1234"
        assert match.group(2) == "/mcp"

    def test_extracts_home_id_with_leading_slash(self):
        match = HOME_PATH_PATTERN.match("/abcd1234/mcp")
        assert match
        assert match.group(1) == "abcd1234"
        assert match.group(2) == "/mcp"

    def test_extracts_home_id_only(self):
        match = HOME_PATH_PATTERN.match("abcd1234")
        assert match
        assert match.group(1) == "abcd1234"
        assert match.group(2) is None


class TestGetHomeAuthEnabled:
    """Tests for get_home_auth_enabled function."""

    def test_returns_true_when_no_settings(self):
        """Should default to auth required when no settings exist."""
        mock_session = MagicMock()
        with patch("homecast.home_app.UserRepository") as mock_repo:
            mock_repo.get_settings.return_value = None
            result = get_home_auth_enabled("user-123", "abcd1234", mock_session)
            assert result is True

    def test_returns_true_when_auth_enabled_true(self):
        """Should return True when auth_enabled is explicitly true."""
        mock_session = MagicMock()
        settings = '{"homes": {"abcd1234": {"auth_enabled": true}}}'
        with patch("homecast.home_app.UserRepository") as mock_repo:
            mock_repo.get_settings.return_value = settings
            result = get_home_auth_enabled("user-123", "abcd1234", mock_session)
            assert result is True

    def test_returns_false_when_auth_disabled(self):
        """Should return False when auth_enabled is false."""
        mock_session = MagicMock()
        settings = '{"homes": {"abcd1234": {"auth_enabled": false}}}'
        with patch("homecast.home_app.UserRepository") as mock_repo:
            mock_repo.get_settings.return_value = settings
            result = get_home_auth_enabled("user-123", "abcd1234", mock_session)
            assert result is False

    def test_returns_true_for_different_home(self):
        """Should default to True when home not in settings."""
        mock_session = MagicMock()
        settings = '{"homes": {"other123": {"auth_enabled": false}}}'
        with patch("homecast.home_app.UserRepository") as mock_repo:
            mock_repo.get_settings.return_value = settings
            result = get_home_auth_enabled("user-123", "abcd1234", mock_session)
            assert result is True

    def test_returns_true_on_invalid_json(self):
        """Should default to True when JSON is invalid."""
        mock_session = MagicMock()
        with patch("homecast.home_app.UserRepository") as mock_repo:
            mock_repo.get_settings.return_value = "invalid json"
            result = get_home_auth_enabled("user-123", "abcd1234", mock_session)
            assert result is True


class TestHomeScopedApp:
    """Integration tests for HomeScopedApp."""

    @pytest.fixture
    def mock_inner_app(self):
        """Create a mock inner app that records calls."""
        async def app(scope, receive, send):
            # Simple response
            await send({
                "type": "http.response.start",
                "status": 200,
                "headers": [(b"content-type", b"application/json")],
            })
            await send({
                "type": "http.response.body",
                "body": b'{"ok": true}',
            })
        return app

    @pytest.fixture
    def mock_home(self):
        """Create a mock home object."""
        home = MagicMock()
        home.user_id = "user-123"
        home.home_id = "abcd1234-5678-90ab-cdef-1234567890ab"
        return home

    def test_rejects_invalid_home_id(self, mock_inner_app):
        """Should return 400 for invalid home_id format."""
        mcp_app = HomeScopedApp(mock_inner_app)
        app = create_test_app(mcp_app)
        client = TestClient(app, raise_server_exceptions=False)

        response = client.get("/home/invalid!/mcp")
        assert response.status_code == 400
        assert "Invalid home_id" in response.json()["error"]

    def test_rejects_unknown_home(self, mock_inner_app):
        """Should return 404 for unknown home."""
        mcp_app = HomeScopedApp(mock_inner_app)
        app = create_test_app(mcp_app)
        client = TestClient(app, raise_server_exceptions=False)

        with patch("homecast.home_app.get_session") as mock_get_session:
            mock_session = MagicMock()
            mock_get_session.return_value.__enter__ = MagicMock(return_value=mock_session)
            mock_get_session.return_value.__exit__ = MagicMock(return_value=False)
            with patch("homecast.home_app.HomeRepository") as mock_repo:
                mock_repo.get_by_prefix.return_value = None

                response = client.get("/home/abcd1234/mcp")
                assert response.status_code == 404
                assert "Unknown home" in response.json()["error"]

    def test_requires_auth_when_enabled(self, mock_inner_app, mock_home):
        """Should return 401 when auth required but no token provided."""
        mcp_app = HomeScopedApp(mock_inner_app)
        app = create_test_app(mcp_app)
        client = TestClient(app, raise_server_exceptions=False)

        with patch("homecast.home_app.get_session") as mock_get_session:
            mock_session = MagicMock()
            mock_get_session.return_value.__enter__ = MagicMock(return_value=mock_session)
            mock_get_session.return_value.__exit__ = MagicMock(return_value=False)
            with patch("homecast.home_app.HomeRepository") as mock_repo:
                mock_repo.get_by_prefix.return_value = mock_home
                with patch("homecast.home_app.get_home_auth_enabled", return_value=True):
                    response = client.get("/home/abcd1234/mcp")
                    assert response.status_code == 401
                    assert "Authentication required" in response.json()["error"]

    def test_allows_unauthenticated_when_auth_disabled(self, mock_inner_app, mock_home):
        """Should allow request when auth is disabled for home."""
        mcp_app = HomeScopedApp(mock_inner_app)
        app = create_test_app(mcp_app)
        client = TestClient(app, raise_server_exceptions=False)

        with patch("homecast.home_app.get_session") as mock_get_session:
            mock_session = MagicMock()
            mock_get_session.return_value.__enter__ = MagicMock(return_value=mock_session)
            mock_get_session.return_value.__exit__ = MagicMock(return_value=False)
            with patch("homecast.home_app.HomeRepository") as mock_repo:
                mock_repo.get_by_prefix.return_value = mock_home
                with patch("homecast.home_app.get_home_auth_enabled", return_value=False):
                    with patch("homecast.home_app.set_home_id"):
                        with patch("homecast.home_app._auth_context_var"):
                            response = client.get("/home/abcd1234/mcp")
                            assert response.status_code == 200

    def test_validates_token_when_provided(self, mock_inner_app, mock_home):
        """Should validate token and return 401 if invalid."""
        mcp_app = HomeScopedApp(mock_inner_app)
        app = create_test_app(mcp_app)
        client = TestClient(app, raise_server_exceptions=False)

        with patch("homecast.home_app.get_session") as mock_get_session:
            mock_session = MagicMock()
            mock_get_session.return_value.__enter__ = MagicMock(return_value=mock_session)
            mock_get_session.return_value.__exit__ = MagicMock(return_value=False)
            with patch("homecast.home_app.HomeRepository") as mock_repo:
                mock_repo.get_by_prefix.return_value = mock_home
                with patch("homecast.home_app.get_home_auth_enabled", return_value=True):
                    with patch("homecast.home_app.extract_token_from_header", return_value="bad-token"):
                        with patch("homecast.home_app.verify_token", return_value=None):
                            response = client.get(
                                "/home/abcd1234/mcp",
                                headers={"Authorization": "Bearer bad-token"}
                            )
                            assert response.status_code == 401
                            assert "Invalid or expired token" in response.json()["error"]

    def test_successful_request_with_valid_token(self, mock_inner_app, mock_home):
        """Should pass through to inner app with valid token."""
        mcp_app = HomeScopedApp(mock_inner_app)
        app = create_test_app(mcp_app)
        client = TestClient(app, raise_server_exceptions=False)

        mock_auth_context = {"user_id": "user-123"}

        with patch("homecast.home_app.get_session") as mock_get_session:
            mock_session = MagicMock()
            mock_get_session.return_value.__enter__ = MagicMock(return_value=mock_session)
            mock_get_session.return_value.__exit__ = MagicMock(return_value=False)
            with patch("homecast.home_app.HomeRepository") as mock_repo:
                mock_repo.get_by_prefix.return_value = mock_home
                with patch("homecast.home_app.get_home_auth_enabled", return_value=True):
                    with patch("homecast.home_app.extract_token_from_header", return_value="good-token"):
                        with patch("homecast.home_app.verify_token", return_value=mock_auth_context):
                            with patch("homecast.home_app.set_home_id") as mock_set_home:
                                with patch("homecast.home_app._auth_context_var") as mock_auth_var:
                                    response = client.get(
                                        "/home/abcd1234/mcp",
                                        headers={"Authorization": "Bearer good-token"}
                                    )
                                    assert response.status_code == 200
                                    # Verify context was set (and then cleaned up)
                                    mock_set_home.assert_any_call("abcd1234")
                                    mock_set_home.assert_called_with(None)  # Cleanup
