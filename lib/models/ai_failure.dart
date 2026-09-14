/// Why an AI request failed, in terms the user can act on.
///
/// Carried by `AiException` so a screen can show a short, translated
/// explanation instead of whatever the provider sent back — which is often a
/// raw JSON error body.
enum AiFailure {
  /// No API key, base URL or model name saved yet.
  missingConfiguration,

  /// The base URL cannot be used as an address.
  invalidUrl,

  /// 401 or 403: the key was refused.
  unauthorized,

  /// 404: nothing at that URL, or the model name does not exist.
  notFound,

  /// 429: too many requests, or the quota is used up.
  rateLimited,

  /// 5xx, still failing after the automatic retries: the provider is down or
  /// overloaded.
  unavailable,

  /// The request never got an answer: offline, DNS, timeout.
  network,

  /// A 2xx that held no usable text.
  emptyResponse,

  /// Any other rejection, or a body that could not be parsed.
  other,
}
