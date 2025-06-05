# status/app/errors.py
"""
Модуль для определения кастомных классов исключений API и их обработчиков.
Это позволяет стандартизировать формат JSON-ответов об ошибках.
Версия 5.0.1: Добавлен импорт Response для type hints.
"""
import logging
from flask import jsonify, Response # Для формирования JSON-ответов
from werkzeug.exceptions import HTTPException # Базовый класс для HTTP-ошибок Werkzeug/Flask
import psycopg2 # Для обработки специфичных ошибок базы данных
from typing import Optional, Dict, Any, Union

# Получаем логгер для этого модуля.
# Имя логгера будет 'app.errors', если этот файл находится в пакете 'app'.
logger = logging.getLogger(__name__)

class ApiException(Exception):
    """
    Базовый класс для всех кастомных API-исключений в приложении.
    Позволяет задавать HTTP-статус код, внутренний код ошибки и сообщение.
    """
    status_code = 500  # HTTP-статус по умолчанию (Internal Server Error)
    error_code = "INTERNAL_ERROR"  # Внутренний код ошибки по умолчанию
    message = "Произошла непредвиденная внутренняя ошибка сервера." # Сообщение по умолчанию
    details = None # Дополнительные детали об ошибке (например, ошибки валидации полей)

    def __init__(self, message: Optional[str] = None,
                 status_code: Optional[int] = None,
                 error_code: Optional[str] = None,
                 details: Optional[Any] = None):
        """
        Конструктор исключения.

        Args:
            message (str, optional): Сообщение об ошибке. Если None, используется self.message.
            status_code (int, optional): HTTP-статус код. Если None, используется self.status_code.
            error_code (str, optional): Внутренний код ошибки. Если None, используется self.error_code.
            details (Any, optional): Дополнительные структурированные детали ошибки.
        """
        super().__init__(message or self.message) # Инициализируем базовый Exception сообщением
        if status_code is not None:
            self.status_code = status_code
        if error_code is not None:
            self.error_code = error_code
        if message is not None: # Если передано кастомное сообщение, используем его
            self.message = message
        if details is not None:
            self.details = details

    def to_dict(self) -> Dict[str, Any]:
        """
        Преобразует объект исключения в словарь, который будет сериализован в JSON.
        Формат ответа: {"error": {"code": "...", "message": "...", "details": ...}}
        """
        rv_error: Dict[str, Any] = {"code": self.error_code, "message": self.message}
        if self.details is not None: # Добавляем детали, только если они есть
            rv_error["details"] = self.details
        return {"error": rv_error}

# --- Конкретные классы API-исключений, наследующиеся от ApiException ---

class ApiNotFound(ApiException):
    """Исключение для ситуаций, когда запрошенный ресурс не найден (HTTP 404)."""
    status_code = 404
    error_code = "NOT_FOUND"
    message = "Запрошенный ресурс не найден."

class ApiBadRequest(ApiException):
    """Исключение для некорректных запросов (HTTP 400)."""
    status_code = 400
    error_code = "BAD_REQUEST"
    message = "Некорректный запрос. Проверьте параметры и тело запроса."

class ApiValidationFailure(ApiBadRequest): # Наследуется от ApiBadRequest
    """
    Исключение для ошибок валидации входных данных (HTTP 422 Unprocessable Entity).
    Обычно содержит поле 'details' со списком ошибок по конкретным полям.
    """
    status_code = 422 # Unprocessable Entity - стандартный код для ошибок валидации
    error_code = "VALIDATION_FAILURE"
    message = "Ошибка валидации входных данных."
    # Поле 'details' будет унаследовано и установлено при создании экземпляра

class ApiConflict(ApiException):
    """Исключение для конфликтов ресурсов (HTTP 409)."""
    status_code = 409
    error_code = "CONFLICT"
    message = "Конфликт ресурсов. Возможно, вы пытаетесь создать уже существующую сущность."

class ApiUnauthorized(ApiException):
    """Исключение для ошибок аутентификации (HTTP 401)."""
    status_code = 401
    error_code = "UNAUTHORIZED"
    message = "Требуется аутентификация. Пожалуйста, предоставьте валидные учетные данные или API-ключ."

class ApiForbidden(ApiException):
    """Исключение для ошибок авторизации, когда доступ запрещен (HTTP 403)."""
    status_code = 403
    error_code = "FORBIDDEN"
    message = "Доступ запрещен. У вас недостаточно прав для выполнения этого действия."

class ApiInternalError(ApiException): # Наследуется от базового ApiException
    """Исключение для общих внутренних ошибок сервера (HTTP 500)."""
    status_code = 500
    error_code = "INTERNAL_SERVER_ERROR" # Более стандартный код
    message = "Произошла непредвиденная ошибка на сервере. Пожалуйста, попробуйте позже."
    # Сообщение по умолчанию изменено на более общее для пользователя

# --- Обработчики ошибок для регистрации в приложении Flask ---

def handle_api_exception(error: ApiException) -> Response:
    """
    Обработчик для всех кастомных исключений, унаследованных от ApiException.
    Логирует ошибку и возвращает стандартизированный JSON-ответ.
    """
    # Логируем ошибку. Для ошибок 500 (внутренние) логируем полный стектрейс.
    if error.status_code >= 500:
        logger.error(f"API Exception (Обработано): Code={error.error_code}, Status={error.status_code}, Msg='{error.message}', Details='{error.details}'", exc_info=True)
    else: # Для клиентских ошибок (4xx) полный стектрейс обычно не нужен
        logger.warning(f"API Exception (Обработано): Code={error.error_code}, Status={error.status_code}, Msg='{error.message}', Details='{error.details}'")

    response = jsonify(error.to_dict())
    response.status_code = error.status_code
    return response

def handle_psycopg2_error(error: psycopg2.Error) -> Response:
    """
    Обработчик для ошибок, возникающих при работе с базой данных через psycopg2.
    Преобразует специфичные ошибки БД в соответствующие API-исключения.
    """
    # Логируем ошибку БД с полным стектрейсом
    logger.error(f"Database Error (Обработано psycopg2.Error): PGCode={error.pgcode}, PGError='{error.pgerror}'", exc_info=True)

    # Преобразуем ошибки psycopg2 в кастомные API-исключения
    # Это позволяет скрыть детали реализации БД от клиента.
    api_error: ApiException
    if isinstance(error, psycopg2.errors.UniqueViolation):
        api_error = ApiConflict(message="Конфликт данных в базе: нарушено ограничение уникальности.")
    elif isinstance(error, psycopg2.errors.ForeignKeyViolation):
        api_error = ApiBadRequest(message="Ошибка целостности данных: нарушено ограничение внешнего ключа.")
    elif isinstance(error, psycopg2.errors.DataError):
         api_error = ApiBadRequest(message=f"Ошибка данных в базе: {error.pgerror or 'некорректные данные для типа столбца'}")
    elif isinstance(error, psycopg2.OperationalError): # Ошибки подключения, таймауты и т.п.
        api_error = ApiInternalError(message=f"Операционная ошибка базы данных: {error.pgerror or 'проблема с подключением или выполнением запроса'}")
    else: # Другие, менее специфичные ошибки БД
        api_error = ApiInternalError(message="Произошла непредвиденная ошибка базы данных.")

    response = jsonify(api_error.to_dict())
    response.status_code = api_error.status_code
    return response

def handle_value_or_type_error(error: Union[ValueError, TypeError]) -> Response: # Python 3.9+ Union
# Или для Python < 3.9: from typing import Union; ... error: Union[ValueError, TypeError]
    """
    Обработчик для стандартных Python ошибок ValueError и TypeError,
    которые часто возникают при неверном типе или значении входных данных.
    Преобразует их в ApiValidationFailure или ApiBadRequest.
    """
    logger.warning(f"Validation/Type Error (Обработано {type(error).__name__}): {error}", exc_info=False) # Не пишем полный стектрейс
    # Решаем, какую ошибку API вернуть
    if "validation" in str(error).lower() or isinstance(error, ValueError): # Если ошибка похожа на валидацию
        api_error = ApiValidationFailure(message=str(error))
    else: # Иначе считаем общим плохим запросом
        api_error = ApiBadRequest(message=f"Ошибка типа или значения: {error}")
    response = jsonify(api_error.to_dict())
    response.status_code = api_error.status_code
    return response

def handle_http_exception(error: HTTPException) -> Response: # Response определен
    """
    Обработчик для стандартных HTTP-ошибок Flask/Werkzeug.
    """
    logger.warning(f"HTTP Exception (Обработано Werkzeug): Code={error.code}, Name='{error.name}', Desc='{error.description}'")
    response_data = {
        "error": {
            "code": error.name.upper().replace(" ", "_") if error.name else "HTTP_ERROR",
            "message": error.description or "Произошла HTTP ошибка."
        }
    }
    response = jsonify(response_data)
    response.status_code = error.code or 500
    return response

def handle_generic_exception(error: Exception) -> Response:
    """
    Обработчик для всех остальных непредвиденных исключений Python.
    Возвращает общую ошибку сервера (500 Internal Server Error).
    """
    logger.exception("Unhandled Exception (Обработано Generic Exception Handler)") # Логируем с полным стеком
    # Не показываем детали внутренней ошибки пользователю из соображений безопасности
    api_error = ApiInternalError()
    response = jsonify(api_error.to_dict())
    response.status_code = api_error.status_code
    return response

def register_error_handlers(app):
    """
    Регистрирует все определенные выше обработчики ошибок в приложении Flask.
    Эта функция должна вызываться при создании экземпляра приложения в app.py.

    Args:
        app (Flask): Экземпляр Flask-приложения.
    """
    logger.info("Регистрация глобальных обработчиков ошибок API...")
    app.register_error_handler(ApiException, handle_api_exception)
    app.register_error_handler(psycopg2.Error, handle_psycopg2_error)
    # Регистрируем обработчики для стандартных ValueError и TypeError
    app.register_error_handler(ValueError, handle_value_or_type_error)
    app.register_error_handler(TypeError, handle_value_or_type_error)
    # Обработчик для стандартных HTTP-ошибок Flask/Werkzeug
    app.register_error_handler(HTTPException, handle_http_exception)
    # Обработчик для всех остальных непредвиденных исключений (должен быть последним)
    app.register_error_handler(Exception, handle_generic_exception)
    logger.info("Глобальные обработчики ошибок API успешно зарегистрированы.")

# Для Python 3.9+ можно использовать Union type hint напрямую:
from typing import Union, Optional, Any, Dict # Добавил остальные нужные