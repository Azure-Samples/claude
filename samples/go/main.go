// Command main calls a Claude model through the standard Anthropic SDK.
//
//	go run .                    print the reply text and token usage
//	go run . -stream            stream the reply text as it arrives
//	go run . "your prompt"      use your own prompt (flags go before the prompt)
//
// It exits 0 only when the reply has text; thinking-only or empty replies and every error
// exit nonzero. Errors report the HTTP status and error type but never the credential, the
// endpoint, the model name or the response body.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/signal"
	"regexp"
	"strings"
	"time"

	"github.com/anthropics/anthropic-sdk-go/v2"

	"github.com/Azure-Samples/claude/samples/go/clientauth"
)

const (
	defaultPrompt = "What are 3 things to visit in Seattle?"
	maxTokens     = 1024
	usage         = "Usage: go run . [-stream] [prompt...]"
)

// totalTimeout is the application policy of this sample, not a helper default: the whole call,
// including SDK retries and streaming, ends after 120 seconds. The SDK's own per-attempt
// timeout and retry defaults are untouched.
const totalTimeout = 120 * time.Second

type runOptions struct {
	clientOverrides
	// totalTimeout bounds the whole call, including SDK retries and streaming.
	totalTimeout time.Duration
}

func main() {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	code := run(ctx, os.Args[1:], os.Getenv, os.Stdout, os.Stderr, runOptions{})
	stop()
	os.Exit(code)
}

func run(ctx context.Context, args []string, getenv func(string) string, stdout, stderr io.Writer, options runOptions) int {
	flags := flag.NewFlagSet("main", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	stream := flags.Bool("stream", false, "stream the reply text")
	if err := flags.Parse(args); err != nil {
		if errors.Is(err, flag.ErrHelp) {
			fmt.Fprintln(stdout, usage)
			return 0
		}
		fmt.Fprintln(stderr, usage)
		return 2
	}
	prompt := strings.TrimSpace(strings.Join(flags.Args(), " "))
	if prompt == "" {
		prompt = defaultPrompt
	}

	total := options.totalTimeout
	if total == 0 {
		total = totalTimeout
	}
	ctx, cancel := context.WithTimeout(ctx, total)
	defer cancel()

	loaded, err := loadSettings(getenv)
	if err != nil {
		fmt.Fprintln(stderr, describeError(ctx, err, total))
		return 1
	}
	client, err := configuredClient(loaded, options.clientOverrides)
	if err != nil {
		fmt.Fprintln(stderr, describeError(ctx, err, total))
		return 1
	}
	params := anthropic.MessageNewParams{
		Model:     anthropic.Model(loaded.model),
		MaxTokens: maxTokens,
		Messages:  []anthropic.MessageParam{anthropic.NewUserMessage(anthropic.NewTextBlock(prompt))},
	}

	var code int
	if *stream {
		code, err = streamReply(ctx, client, params, stdout, stderr)
	} else {
		code, err = printReply(ctx, client, params, stdout, stderr)
	}
	if err != nil {
		fmt.Fprintln(stderr, describeError(ctx, err, total))
		return 1
	}
	return code
}

func printReply(ctx context.Context, client anthropic.Client, params anthropic.MessageNewParams, stdout, stderr io.Writer) (int, error) {
	message, err := client.Messages.New(ctx, params)
	if err != nil {
		return 0, err
	}
	hasText := false
	for _, block := range message.Content {
		if block.Type == "text" && strings.TrimSpace(block.Text) != "" {
			fmt.Fprintln(stdout, block.Text)
			hasText = true
		}
	}
	if !hasText {
		return noText(string(message.StopReason), stderr), nil
	}
	fmt.Fprintf(stdout, "\n[usage] input=%d output=%d\n", message.Usage.InputTokens, message.Usage.OutputTokens)
	return 0, nil
}

func streamReply(ctx context.Context, client anthropic.Client, params anthropic.MessageNewParams, stdout, stderr io.Writer) (int, error) {
	stream := client.Messages.NewStreaming(ctx, params)
	defer stream.Close()
	var message anthropic.Message
	hasText := false
	for stream.Next() {
		event := stream.Current()
		if err := message.Accumulate(event); err != nil {
			return 0, err
		}
		if delta, ok := event.AsAny().(anthropic.ContentBlockDeltaEvent); ok {
			if text, ok := delta.Delta.AsAny().(anthropic.TextDelta); ok {
				hasText = hasText || strings.TrimSpace(text.Text) != ""
				io.WriteString(stdout, text.Text)
			}
		}
	}
	if err := stream.Err(); err != nil {
		return 0, err
	}
	io.WriteString(stdout, "\n")
	if !hasText {
		return noText(string(message.StopReason), stderr), nil
	}
	return 0, nil
}

func noText(stopReason string, stderr io.Writer) int {
	fmt.Fprintf(stderr, "No text response (stop_reason=%s). Increase max_tokens if the response exhausted its budget.\n", stopReason)
	return 1
}

var errorType = regexp.MustCompile(`^[a-z_]{1,64}$`)

func describeError(ctx context.Context, err error, total time.Duration) string {
	var (
		config    *configError
		setup     *credentialSetupError
		api       *anthropic.Error
		transport *url.Error
	)
	switch {
	case errors.As(err, &config):
		return config.Error()
	case errors.As(err, &setup):
		return "Could not create the Azure credential. Check AZURE_TOKEN_CREDENTIALS, AZURE_TENANT_ID and AZURE_CLIENT_ID."
	case errors.Is(err, clientauth.ErrCredentialProvider):
		return "The credential provider failed. Sign in with the Azure CLI or select another AZURE_TOKEN_CREDENTIALS."
	case errors.Is(err, clientauth.ErrInvalidCredential):
		return "The credential provider returned an invalid value."
	case errors.Is(err, clientauth.ErrDifferentOrigin):
		return "Refusing to send credentials to a different origin."
	case errors.Is(err, clientauth.ErrRedirectRefused):
		return "The endpoint answered with a redirect, which is never followed."
	case errors.As(err, &api):
		label := ""
		if kind := string(api.Type()); errorType.MatchString(kind) {
			label = " (" + kind + ")"
		}
		message := fmt.Sprintf("Request failed with HTTP %d%s.", api.StatusCode, label)
		if hint := httpHint(api.StatusCode); hint != "" {
			message += " " + hint
		}
		return message
	case errors.Is(err, context.DeadlineExceeded):
		if ctx.Err() != nil {
			return fmt.Sprintf("Request timed out after %g seconds.", total.Seconds())
		}
		return "Request timed out."
	case errors.Is(err, context.Canceled):
		return "Request was cancelled."
	case errors.As(err, &transport):
		return "Could not connect to the endpoint."
	}
	return fmt.Sprintf("Unexpected error (%T).", err)
}

func httpHint(status int) string {
	switch {
	case status >= 300 && status < 400:
		return "The endpoint answered with a redirect, which is never followed."
	case status == 401:
		return "The credential was rejected. Check AUTH_MODE, the token scope or the API key."
	case status == 403:
		return "The caller is not permitted to use this resource. Check its role assignment or key."
	case status == 404:
		return "The endpoint path or model name was not found. Check the base URL and model settings."
	case status == 429:
		return "The request was rate limited. Retry later."
	case status >= 500:
		return "The service reported an error. Retry later."
	}
	return ""
}
