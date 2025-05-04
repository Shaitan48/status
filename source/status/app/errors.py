# status/app/errors.py
from flask import jsonify
from werkzeug.exceptions import HTTPException
import psycopg2
import logging

# Получаем логгер приложения (он будет настроен в app.py)
logger = logging.getLogger(__name__)

class ApiException(Exception):
    """Базовый класс для API-ошибок."""
    status_code = 500
    error_code = "INTERNAL_ERROR"
    message = "An unexpected internal error occurred."
    details = None

    def __init__(self, message=None, status_code=None, error_code=None, details=None):
        super().__init__(message or self.message)
        if status_code is not None:
            self.status_code = status_code
        if error_code is not None:
            self.error_code = error_code
        if message is not None:
            self.message = message
        if details is not None:
            self.details = details

    def to_dict(self):
        rv = {"error": {"code": self.error_code, "message": self.message}}
        if self.details:
            rv["error"]["details"] = self.details
        return rv

# --- Конкретные классы ошибок ---

class ApiNotFound(ApiException):
    status_code = 404
    error_code = "NOT_FOUND"
    message = "Resource not found."

class ApiBadRequest(ApiException):
    status_code = 400
    error_code = "BAD_REQUEST"
    message = "Bad request."

class ApiValidationFailure(ApiBadRequest):
    status_code = 422
    error_code = "VALIDATION_FAILURE"
    message = "Input validation failed."

class ApiConflict(ApiException):
    status_code = 409
    error_code = "CONFLICT"
    message = "Resource conflict."

class ApiUnauthorized(ApiException):
    status_code = 401
    error_code = "UNAUTHORIZED"
    message = "Authentication required."

class ApiForbidden(ApiException):
    status_code = 403
    error_code = "FORBIDDEN"
    message = "Permission denied."

class ApiInternalError(ApiException):
    status_code = 500
    error_code = "INTERNAL_ERROR"
    message = "An unexpected internal server error occurred."

# --- Обработчики ошибок Flask ---

def handle_api_exception(error: ApiException):
    """Обработчик для кастомных API-ошибок."""
    logger.warning(f"API Exception: {error.error_code} - {error.message}", exc_info=(error.status_code == 500))
    response = jsonify(error.to_dict())
    response.status_code = error.status_code
    return response

def handle_psycopg2_error(error: psycopg2.Error):
    """Обработчик для ошибок psycopg2."""
    # Можно детализировать маппинг ошибок БД на API-ошибки
    logger.error(f"Database Error: {error.pgcode} - {error.pgerror}", exc_info=True)
    if isinstance(error, psycopg2.errors.UniqueViolation):
        api_error = ApiConflict(message="Database conflict: Unique constraint violated.")
    elif isinstance(error, psycopg2.errors.ForeignKeyViolation):
        api_error = ApiBadRequest(message="Database error: Foreign key constraint violated.")
    elif isinstance(error, psycopg2.errors.DataError):
         api_error = ApiBadRequest(message=f"Database data error: {error.pgerror}")
    elif isinstance(error, psycopg2.OperationalError):
        api_error = ApiInternalError(message=f"Database operational error: {error}")
    else:
        api_error = ApiInternalError(message="An unexpected database error occurred.")

    response = jsonify(api_error.to_dict())
    response.status_code = api_error.status_code
    return response

def handle_validation_error(error: ValueError):
    """Обработчик для ValueError (часто используется для валидации)."""
    logger.warning(f"Validation Error (ValueError): {error}", exc_info=False) # Не пишем stacktrace для ValueError
    api_error = ApiValidationFailure(message=str(error))
    response = jsonify(api_error.to_dict())
    response.status_code = api_error.status_code
    return response

def handle_type_error(error: TypeError):
    """Обработчик для TypeError (может возникать при некорректных данных)."""
    logger.warning(f"Type Error: {error}", exc_info=False)
    api_error = ApiBadRequest(message=f"Type error: {error}")
    response = jsonify(api_error.to_dict())
    response.status_code = api_error.status_code
    return response

def handle_http_exception(error: HTTPException):
    """Обработчик для стандартных HTTP-ошибок Flask/Werkzeug."""
    logger.warning(f"HTTP Exception: {error.code} - {error.name}: {error.description}")
    response = jsonify(
        {"error": {"code": error.name.upper().replace(" ", "_"), "message": error.description}}
    )
    response.status_code = error.code
    return response

def handle_generic_exception(error: Exception):
    """Обработчик для всех остальных непредвиденных ошибок."""
    logger.exception("Unhandled Exception caught") # Логируем с полным стеком
    api_error = ApiInternalError() # Не показываем детали внутренней ошибки пользователю
    response = jsonify(api_error.to_dict())
    response.status_code = api_error.status_code
    return response

def register_error_handlers(app):
    """Регистрирует все обработчики ошибок в приложении Flask."""
    app.register_error_handler(ApiException, handle_api_exception)
    app.register_error_handler(psycopg2.Error, handle_psycopg2_error)
    app.register_error_handler(ValueError, handle_validation_error)
    app.register_error_handler(TypeError, handle_type_error)
    app.register_error_handler(HTTPException, handle_http_exception)
    app.register_error_handler(Exception, handle_generic_exception)
    logger.info("API error handlers registered.")