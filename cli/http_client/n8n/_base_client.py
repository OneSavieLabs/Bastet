import httpx
from typing import Any, Dict, Optional, Union, Type, TypeVar, cast
import json
import logging
import platform
from urllib.parse import urlparse, urlunparse

# Type definitions 
#TODO understand the design -> openAI / src / _base_client.py
T = TypeVar('T')
ResponseT = TypeVar('ResponseT')

class APIError(Exception):
    """Base exception for all API errors."""
    
    message: str
    request: httpx.Request
    
    body: Optional[Dict[str, Any]] = None
    status_code: Optional[int] = None
    
    def __init__(self, message: str, request: httpx.Request, *, body: Optional[Dict[str, Any]] = None) -> None:
        super().__init__(message)
        self.message = message
        self.request = request
        self.body = body

class APIStatusError(APIError):
    """Raised when the API returns a non-success status code."""
    
    response: httpx.Response
    status_code: int
    
    def __init__(self, message: str, *, response: httpx.Response, body: Optional[Dict[str, Any]] = None) -> None:
        super().__init__(message, response.request, body=body)
        self.response = response
        self.status_code = response.status_code

class APIConnectionError(APIError):
    """Raised when there's a connection error."""
    
    def __init__(self, *, message: str = "Connection error", request: httpx.Request) -> None:
        super().__init__(message, request, body=None)

class APITimeoutError(APIConnectionError):
    """Raised when a request times out."""
    
    def __init__(self, request: httpx.Request) -> None:
        super().__init__(message="Request timed out", request=request)

class AuthenticationError(APIStatusError):
    """Raised when authentication fails."""
    pass

class RateLimitError(APIStatusError):
    """Raised when rate limit is exceeded."""
    pass

class NotFoundError(APIStatusError):
    """Raised when a resource is not found."""
    pass

class BaseHttpClient:
    """Base HTTP client for making API requests."""
    
    def __init__(
        self, 
        X_N8N_API_KEY: str,
        N8N_API_BASE_URL: str,
        timeout: int = 30,
        max_retries: int = 3
    ):
        self.api_key = X_N8N_API_KEY
        self.base_url = self._remove_trailing_slash(N8N_API_BASE_URL)
        self.timeout = timeout
        self.max_retries = max_retries
        self.logger = logging.getLogger(__name__)
        
        # Init client with default settings
        self._client = httpx.AsyncClient(
            timeout=timeout,
            headers=self._build_default_headers()
        )
    
    def _remove_trailing_slash(self, url: str) -> str:
        """Normalize the base URL by ensuring it doesn't end with a slash."""
        return url.rstrip('/')
    
    def _build_default_headers(self) -> Dict[str, str]:
        """Build default header for all requests."""
        headers = {
            "X-N8N-API-KEY": self.api_key,
            "Content-Type": "application/json",
            "Accept": "application/json",
        }
        return headers
    
    def _check_start_with_slash(self, endpoint: str) -> str:
        """Ensure the endpoint starts with a slash."""
        if not endpoint.startswith('/'):
            endpoint = '/' + endpoint
        return f"{self.base_url}{endpoint}"
    
    def _handle_response(self, response: httpx.Response) -> Any:
        """Handle the API response and return the parsed data."""
        try:
            response.raise_for_status()
            
            # Check if response is JSON
            if response.headers.get("content-type", "").startswith("application/json"):
                return response.json()
            return response.text
            
        except httpx.HTTPStatusError as e:
            self._handle_error_response(e.response)
    
    def _handle_error_response(self, response: httpx.Response) -> None:
        """Handle error responses from the API."""
        error_data = None
        try:
            if response.headers.get("content-type", "").startswith("application/json"):
                error_data = response.json()
        except Exception:
            error_data = {"error": response.text}
        
        error_message = f"HTTP Statu:s {response.status_code}"
        if error_data and isinstance(error_data, dict):
            error_message = error_data.get("message", error_data.get("error", error_message))
        
        if response.status_code == 401:
            raise AuthenticationError(message=f"Authentication failed: {error_message}", response=response, body=error_data)
        elif response.status_code == 404:
            raise NotFoundError(message=f"Resource not found: {error_message}", response=response, body=error_data)
        elif response.status_code == 429:
            raise RateLimitError(message=f"Rate limit exceeded: {error_message}", response=response, body=error_data)
        else:
            raise APIStatusError(message=f"API request failed: {error_message}", response=response, body=error_data)
    
    async def _request(
        self,
        method: str,
        endpoint: str,
        params: Optional[Dict[str, Any]] = None,
        data: Optional[Dict[str, Any]] = None,
        json_data: Optional[Dict[str, Any]] = None,
        headers: Optional[Dict[str, Any]] = None,
        timeout: Optional[int] = None,
        retries: Optional[int] = None
    ) -> Any:
        """
        Base method to make HTTP requests to the API.
        
        Args:
            method: HTTP method (GET, POST, PUT, DELETE)
            endpoint: API endpoint (without base URL)
            params: URL parameters
            data: Form data
            json_data: JSON data
            headers: Additional headers
            timeout: Request timeout (seconds)
            retries: Number of retries for the request
        """
        url = self._check_start_with_slash(endpoint)
        request_headers = self._client.headers.copy()
        
        if headers:
            request_headers.update(headers)
        
        timeout_value = timeout if timeout is not None else self.timeout
        max_retries = retries if retries is not None else self.max_retries
        
        self.logger.debug(f"Making {method} request to {url}")
        
        retry_count = 0
        
        while True:
            try:
                response = await self._client.request(
                    method=method,
                    url=url,
                    params=params,
                    data=data,
                    json=json_data,
                    headers=request_headers,
                    timeout=timeout_value
                )
                
                return self._handle_response(response)
                
            except httpx.TimeoutException as e:
                if retry_count >= max_retries:
                    self.logger.error(f"Request timed out after {max_retries} retries")
                    raise APITimeoutError(request=e.request)
                
                retry_count += 1
                self.logger.warning(f"Request timed out, retrying ({retry_count}/{max_retries})")
                
            except httpx.RequestError as e:
                if retry_count >= max_retries:
                    self.logger.error(f"Connection error after {max_retries} retries: {str(e)}")
                    raise APIConnectionError(message=f"Connection error: {str(e)}", request=e.request)
                
                retry_count += 1
                self.logger.warning(f"Connection error, retrying ({retry_count}/{max_retries}): {str(e)}")
                
            except Exception as e:
                self.logger.error(f"Unexpected error: {str(e)}")
                raise
    
    async def get(self, endpoint: str, params: Optional[Dict[str, Any]] = None, **kwargs) -> Any:
        """Make a GET request to the API."""
        return await self._request("GET", endpoint, params=params, **kwargs)
    
    async def post(self, endpoint: str, json_data: Optional[Dict[str, Any]] = None, **kwargs) -> Any:
        """Make a POST request to the API."""
        return await self._request("POST", endpoint, json_data=json_data, **kwargs)
    
    async def put(self, endpoint: str, json_data: Optional[Dict[str, Any]] = None, **kwargs) -> Any:
        """Make a PUT request to the API."""
        return await self._request("PUT", endpoint, json_data=json_data, **kwargs)
    
    async def delete(self, endpoint: str, **kwargs) -> Any:
        """Make a DELETE request to the API."""
        return await self._request("DELETE", endpoint, **kwargs)
    
    async def close(self) -> None:
        """Close the HTTP client session."""
        if self._client:
            await self._client.aclose()
    
    def __aenter__(self) -> 'BaseHttpClient':
        return self
    
    async def __aexit__(self, exc_type, exc_val, exc_tb) -> None:
        await self.close()