package main

import (
	"context"
	"fmt"
	"io"
	"strings"

	"github.com/anthropics/anthropic-sdk-go/v2"
)

const (
	threadSystem = "Keep replies short."
	threadFirst  = "Remember the code ORCHID-47. Reply with OK."
	threadSecond = "What code did I ask you to remember? Reply with only the code."
)

// threadReply sends two turns on one message thread (beta) and prints the second reply. The SDK helper creates
// the thread, continues it with only the new message, sets the beta header, and replays the conversation once
// if a continue request fails with thread_not_found (or thread_already_continued or thread_continue_in_flight).
// A thread is best effort, so the helper's history is the source of truth; there is no unthreaded fallback.
func threadReply(ctx context.Context, client anthropic.Client, model string, stdout, stderr io.Writer) (int, error) {
	thread := client.Beta.Messages.NewThread(anthropic.BetaMessageThreadCreateParams{
		Model:     anthropic.Model(model),
		MaxTokens: maxTokens,
		System:    []anthropic.BetaTextBlockParam{{Text: threadSystem}},
	})
	var reply *anthropic.BetaMessage
	for _, prompt := range []string{threadFirst, threadSecond} {
		var err error
		reply, err = thread.Send(ctx, anthropic.BetaMessageThreadSendParams{
			Messages: []anthropic.BetaMessageParam{anthropic.NewBetaUserMessage(anthropic.NewBetaTextBlock(prompt))},
		})
		if err != nil {
			return 0, err
		}
	}
	hasText := false
	for _, block := range reply.Content {
		if block.Type == "text" && strings.TrimSpace(block.Text) != "" {
			fmt.Fprintln(stdout, block.Text)
			hasText = true
		}
	}
	if !hasText {
		return noText(string(reply.StopReason), stderr), nil
	}
	return 0, nil
}
