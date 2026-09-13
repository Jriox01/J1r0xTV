package tv.j1r0x.app.data.api

class ApiHttpException(
    val statusCode: Int,
    val endpoint: String,
) : RuntimeException(apiHttpUserMessage(statusCode))

fun apiHttpUserMessage(statusCode: Int): String = when (statusCode) {
    400 -> "Источник отклонил запрос. Выберите другой источник."
    404 -> "Запрошенные данные больше недоступны."
    500, 502, 503, 504 -> "Сервер временно не может обработать запрос. Нажмите “Повторить”."
    else -> "Ошибка сервера ($statusCode). Нажмите “Повторить”."
}
