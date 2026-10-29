package sample.anthropic;

import com.anthropic.client.AnthropicClient;
import com.anthropic.client.okhttp.AnthropicOkHttpClient;
import com.anthropic.core.RequestOptions;
import com.anthropic.core.http.HttpClient;
import com.anthropic.core.http.HttpRequest;
import com.anthropic.core.http.HttpResponse;
import com.anthropic.core.http.Interceptor;
import java.net.URI;
import java.net.URISyntaxException;
import java.time.Duration;
import java.util.List;
import java.util.Locale;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.CompletionException;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Executor;
import java.util.concurrent.atomic.AtomicReference;
import java.util.function.Supplier;
import java.util.regex.Pattern;

/**
 * Builds the standard {@link AnthropicClient} with one explicitly chosen credential. It adds no client
 * subclass and no Messages API of its own; calls, streaming, status errors and retries stay with the SDK.
 *
 * <p>The factory neither reads environment variables or system properties nor knows any identity library.
 * It never calls {@code fromEnv()} or sets the SDK's {@code apiKey}/{@code authToken}, so nothing ambient is
 * discovered, and it registers one public SDK {@link Interceptor}. On every attempt (retries included) that
 * interceptor refuses a request that is not for the configured origin, removes every credential header
 * ({@code Authorization}, {@code x-api-key}, {@code api-key}), sets the chosen one, disables redirect
 * following and refuses redirect responses. Other headers, such as {@code anthropic-beta}, are left alone.
 *
 * <p>The interceptor decorates the SDK's {@link HttpClient}, so it covers both execution modes. Blocking calls
 * run the token supplier on the calling thread. {@code client.async()} calls run it on the
 * {@link Options.Builder#tokenExecutor token executor}, so neither the caller nor the SDK's callback threads wait
 * for it. Cancelling the future the interceptor returns cancels the request it has not sent yet or the in-flight
 * SDK future; a token fetch that is already running is not interrupted.
 */
public final class ClientFactory {

    /** The header used for an API key when none is chosen: {@code Authorization: Bearer}. */
    public static final String DEFAULT_API_KEY_HEADER = "Authorization";

    private static final List<String> CREDENTIAL_HEADER_NAMES = List.of("Authorization", "x-api-key", "api-key");
    private static final Pattern HEADER_NAME = Pattern.compile("[!#$%&'*+\\-.^_`|~0-9A-Za-z]+");
    private static final Pattern IPV4_LOOPBACK = Pattern.compile("127(\\.\\d{1,3}){3}");

    private ClientFactory() {}

    /** Settings for {@link #create}. Configure exactly one of the token supplier and the API key. */
    public static final class Options {
        private final String baseUrl;
        private final Supplier<String> tokenSupplier;
        private final String apiKey;
        private final String apiKeyHeader;
        private final String apiVersion;
        private final Duration timeout;
        private final Integer maxRetries;
        private final Executor tokenExecutor;

        private Options(Builder builder) {
            this.baseUrl = builder.baseUrl;
            this.tokenSupplier = builder.tokenSupplier;
            this.apiKey = builder.apiKey;
            this.apiKeyHeader = builder.apiKeyHeader;
            this.apiVersion = builder.apiVersion;
            this.timeout = builder.timeout;
            this.maxRetries = builder.maxRetries;
            this.tokenExecutor = builder.tokenExecutor;
        }

        public static Builder builder() {
            return new Builder();
        }

        /** Builder for {@link Options}. */
        public static final class Builder {
            private String baseUrl;
            private Supplier<String> tokenSupplier;
            private String apiKey;
            private String apiKeyHeader = DEFAULT_API_KEY_HEADER;
            private String apiVersion;
            private Duration timeout;
            private Integer maxRetries;
            private Executor tokenExecutor;

            private Builder() {}

            /**
             * Absolute service endpoint, for example {@code https://api.anthropic.com}. Must be https, except
             * that plain http is accepted for loopback test servers. The credential is bound to this origin.
             */
            public Builder baseUrl(String baseUrl) {
                this.baseUrl = baseUrl;
                return this;
            }

            /**
             * Per-attempt bearer token, sent as {@code Authorization: Bearer}. Called before every attempt,
             * including SDK retries, and never cached by the factory: expiry, refresh and caching belong to the
             * supplier. The caller owns the supplier and whatever it wraps; closing the client does not close them.
             * Blocking calls run it on the calling thread; {@code client.async()} calls run it on
             * {@link #tokenExecutor}.
             */
            public Builder tokenSupplier(Supplier<String> tokenSupplier) {
                this.tokenSupplier = tokenSupplier;
                return this;
            }

            /**
             * Where the {@link #tokenSupplier} runs for {@code client.async()} calls, so a supplier that blocks (a
             * CLI credential starts a subprocess) never blocks the caller or the SDK's callback threads. When not
             * set the JDK's default asynchronous pool is used. Ignored with an API key; blocking calls never use it.
             */
            public Builder tokenExecutor(Executor tokenExecutor) {
                this.tokenExecutor = tokenExecutor;
                return this;
            }

            /** Static key, placed in {@link #apiKeyHeader}. */
            public Builder apiKey(String apiKey) {
                this.apiKey = apiKey;
                return this;
            }

            /**
             * Header that carries the API key. {@code Authorization} (the default) sends {@code Bearer <key>};
             * any other name, such as {@code x-api-key}, sends the raw key.
             */
            public Builder apiKeyHeader(String apiKeyHeader) {
                this.apiKeyHeader = apiKeyHeader;
                return this;
            }

            /** Value for {@code anthropic-version}. When null the SDK default is left untouched. */
            public Builder apiVersion(String apiVersion) {
                this.apiVersion = apiVersion;
                return this;
            }

            /**
             * Maximum time for one HTTP call, not including SDK retries. When not set the SDK default is kept;
             * the factory never picks a timeout of its own.
             */
            public Builder timeout(Duration timeout) {
                this.timeout = timeout;
                return this;
            }

            /** SDK retry count. When not set the SDK default is kept. */
            public Builder maxRetries(int maxRetries) {
                this.maxRetries = maxRetries;
                return this;
            }

            public Options build() {
                return new Options(this);
            }
        }
    }

    /**
     * Creates the client. The caller closes it.
     *
     * @throws IllegalArgumentException if the options are missing, ambiguous or unsafe
     */
    public static AnthropicClient create(Options options) {
        if (options == null) {
            throw new IllegalArgumentException("options must not be null");
        }

        URI baseUri = parseBaseUrl(options.baseUrl);

        if ((options.tokenSupplier == null) == (options.apiKey == null)) {
            throw new IllegalArgumentException("Configure exactly one credential: set either tokenSupplier or apiKey.");
        }
        if (options.apiKey != null && !isCredentialValue(options.apiKey)) {
            throw new IllegalArgumentException("apiKey is empty or contains whitespace or control characters.");
        }
        if (options.apiKeyHeader == null || !HEADER_NAME.matcher(options.apiKeyHeader).matches()) {
            throw new IllegalArgumentException("apiKeyHeader is not a valid HTTP header name.");
        }
        if (options.apiVersion != null && !isCredentialValue(options.apiVersion)) {
            throw new IllegalArgumentException("apiVersion is empty or contains whitespace or control characters.");
        }
        if (options.timeout != null && (options.timeout.isZero() || options.timeout.isNegative())) {
            throw new IllegalArgumentException("timeout must be positive.");
        }
        if (options.maxRetries != null && options.maxRetries < 0) {
            throw new IllegalArgumentException("maxRetries must not be negative.");
        }

        AnthropicOkHttpClient.Builder builder = AnthropicOkHttpClient.builder()
                .baseUrl(baseUri.toString())
                .addInterceptor(interceptor(baseUri, options));
        if (options.timeout != null) {
            builder.timeout(options.timeout);
        }
        if (options.maxRetries != null) {
            builder.maxRetries(options.maxRetries);
        }

        return builder.build();
    }

    /** The interceptor {@link #create} installs; package-private so tests can drive it with a fake HttpClient. */
    static Interceptor interceptor(URI baseUri, Options options) {
        return new RequestAuthorizer(originOf(baseUri), options.tokenSupplier, options.apiKey, options.apiKeyHeader,
                options.apiVersion, options.tokenExecutor);
    }

    private static URI parseBaseUrl(String baseUrl) {
        URI uri;
        try {
            uri = new URI(baseUrl == null ? "" : baseUrl);
        } catch (URISyntaxException e) {
            throw new IllegalArgumentException("baseUrl must be an absolute URL.");
        }

        String scheme = uri.getScheme() == null ? "" : uri.getScheme().toLowerCase(Locale.ROOT);
        if (!uri.isAbsolute() || uri.getHost() == null) {
            throw new IllegalArgumentException("baseUrl must be an absolute URL.");
        }
        boolean https = scheme.equals("https");
        boolean loopbackHttp = scheme.equals("http") && isLoopbackHost(uri.getHost());
        if (!https && !loopbackHttp) {
            throw new IllegalArgumentException("baseUrl must use https; plain http is accepted only for loopback test servers.");
        }
        if (uri.getRawUserInfo() != null || uri.getRawQuery() != null || uri.getRawFragment() != null) {
            throw new IllegalArgumentException("baseUrl must not contain user info, a query or a fragment.");
        }

        return uri;
    }

    private static boolean isLoopbackHost(String host) {
        return host.equalsIgnoreCase("localhost")
                || IPV4_LOOPBACK.matcher(host).matches()
                || host.equals("[::1]");
    }

    private static String originOf(URI uri) {
        String scheme = uri.getScheme().toLowerCase(Locale.ROOT);
        int port = uri.getPort() >= 0 ? uri.getPort() : (scheme.equals("https") ? 443 : 80);
        return scheme + "://" + uri.getHost().toLowerCase(Locale.ROOT) + ":" + port;
    }

    private static boolean isCredentialValue(String value) {
        if (value.isEmpty()) {
            return false;
        }
        for (int i = 0; i < value.length(); i++) {
            char c = value.charAt(i);
            if (c <= ' ' || c >= '\u007f') {
                return false;
            }
        }
        return true;
    }

    private static boolean isRedirect(int status) {
        return status == 301 || status == 302 || status == 303 || status == 307 || status == 308;
    }

    private static final class RequestAuthorizer implements Interceptor {
        private final String boundOrigin;
        private final Supplier<String> tokenSupplier;
        private final String apiKey;
        private final String apiKeyHeader;
        private final String apiVersion;
        private final Executor tokenExecutor;

        RequestAuthorizer(
                String boundOrigin,
                Supplier<String> tokenSupplier,
                String apiKey,
                String apiKeyHeader,
                String apiVersion,
                Executor tokenExecutor) {
            this.boundOrigin = boundOrigin;
            this.tokenSupplier = tokenSupplier;
            this.apiKey = apiKey;
            this.apiKeyHeader = apiKeyHeader;
            this.apiVersion = apiVersion;
            this.tokenExecutor = tokenExecutor;
        }

        @Override
        public HttpClient intercept(HttpClient next) {
            return new HttpClient() {
                @Override
                public HttpResponse execute(HttpRequest request, RequestOptions requestOptions) {
                    return RequestAuthorizer.this.execute(next, request, requestOptions);
                }

                @Override
                public CompletableFuture<HttpResponse> executeAsync(HttpRequest request, RequestOptions requestOptions) {
                    return RequestAuthorizer.this.executeAsync(next, request, requestOptions);
                }

                @Override
                public void close() {
                    next.close();
                }
            };
        }

        HttpResponse execute(HttpClient next, HttpRequest request, RequestOptions requestOptions) {
            // Checked before the supplier runs so a request for another origin never costs a token.
            ensureBoundOrigin(request.baseUrl());
            HttpRequest authorized = authorize(request, tokenSupplier == null ? null : readToken());

            HttpResponse response = next.execute(authorized, withoutRedirects(requestOptions));
            IllegalStateException redirect = closeIfRedirect(response);
            if (redirect != null) {
                throw redirect;
            }
            return response;
        }

        CompletableFuture<HttpResponse> executeAsync(HttpClient next, HttpRequest request, RequestOptions requestOptions) {
            CompletableFuture<HttpRequest> credentialed;
            try {
                ensureBoundOrigin(request.baseUrl());
                credentialed = tokenSupplier == null
                        ? CompletableFuture.completedFuture(authorize(request, null))
                        : supplyToken().thenApply(token -> authorize(request, token));
            } catch (RuntimeException e) {
                return CompletableFuture.failedFuture(e);
            }

            CompletableFuture<HttpResponse> result = new CompletableFuture<>();
            AtomicReference<CompletableFuture<HttpResponse>> inFlight = new AtomicReference<>();
            credentialed.whenComplete((authorized, failure) -> {
                if (failure != null) {
                    result.completeExceptionally(unwrapped(failure));
                } else if (!result.isDone()) {
                    send(next, authorized, requestOptions, result, inFlight);
                }
            });
            result.whenComplete((response, failure) -> {
                if (result.isCancelled()) {
                    credentialed.cancel(true);
                    CompletableFuture<HttpResponse> sent = inFlight.get();
                    if (sent != null) {
                        sent.cancel(true);
                    }
                }
            });
            return result;
        }

        private void send(
                HttpClient next,
                HttpRequest authorized,
                RequestOptions requestOptions,
                CompletableFuture<HttpResponse> result,
                AtomicReference<CompletableFuture<HttpResponse>> inFlight) {
            CompletableFuture<HttpResponse> sent;
            try {
                sent = next.executeAsync(authorized, withoutRedirects(requestOptions));
            } catch (RuntimeException e) {
                result.completeExceptionally(e);
                return;
            }

            inFlight.set(sent);
            sent.whenComplete((response, failure) -> {
                if (failure != null) {
                    result.completeExceptionally(unwrapped(failure));
                    return;
                }
                IllegalStateException redirect = closeIfRedirect(response);
                if (redirect != null) {
                    result.completeExceptionally(redirect);
                } else if (!result.complete(response)) {
                    response.close();
                }
            });
            if (result.isCancelled()) {
                sent.cancel(true);
            }
        }

        private CompletableFuture<String> supplyToken() {
            return tokenExecutor == null
                    ? CompletableFuture.supplyAsync(this::readToken)
                    : CompletableFuture.supplyAsync(this::readToken, tokenExecutor);
        }

        private String readToken() {
            String token = tokenSupplier.get();
            if (token == null || !isCredentialValue(token)) {
                throw new IllegalStateException(
                        "The token supplier returned an empty token or one with whitespace or control characters.");
            }
            return token;
        }

        private HttpRequest authorize(HttpRequest request, String token) {
            String headerName;
            String headerValue;
            if (tokenSupplier != null) {
                headerName = "Authorization";
                headerValue = "Bearer " + token;
            } else {
                headerName = apiKeyHeader;
                headerValue = apiKeyHeader.equalsIgnoreCase("Authorization") ? "Bearer " + apiKey : apiKey;
            }

            HttpRequest.Builder authorized = request.toBuilder();
            for (String name : CREDENTIAL_HEADER_NAMES) {
                authorized.removeHeaders(name);
            }
            // Credentials are set above this interceptor by the SDK, so replace rather than append.
            authorized.replaceHeaders(headerName, headerValue);
            if (apiVersion != null) {
                authorized.replaceHeaders("anthropic-version", apiVersion);
            }
            return authorized.build();
        }

        private static RequestOptions withoutRedirects(RequestOptions requestOptions) {
            return requestOptions.toBuilder().followRedirects(false).build();
        }

        /** Closes a redirect response and returns the failure to raise for it; null for any other response. */
        private IllegalStateException closeIfRedirect(HttpResponse response) {
            int status = response.statusCode();
            if (!isRedirect(status)) {
                return null;
            }
            response.close();
            return new IllegalStateException("Refused an HTTP " + status + " redirect: credentials are bound to "
                    + boundOrigin + " and redirects are not followed.");
        }

        /** Strips the future wrappers so a failure surfaces with its own type, as in the blocking path. */
        private static Throwable unwrapped(Throwable failure) {
            Throwable cause = failure;
            while ((cause instanceof CompletionException || cause instanceof ExecutionException)
                    && cause.getCause() != null) {
                cause = cause.getCause();
            }
            return cause;
        }

        private void ensureBoundOrigin(String requestBaseUrl) {
            String origin;
            try {
                origin = originOf(new URI(requestBaseUrl));
            } catch (URISyntaxException | RuntimeException e) {
                origin = "";
            }
            if (!origin.equals(boundOrigin)) {
                throw new IllegalStateException(
                        "Refused a request outside " + boundOrigin + "; credentials are bound to that origin.");
            }
        }
    }
}