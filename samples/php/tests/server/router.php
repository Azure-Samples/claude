<?php

declare(strict_types=1);

// Test server for EndToEndTest. It answers Messages requests with the request headers it received, as the reply text.

$path = (string) parse_url($_SERVER['REQUEST_URI'], PHP_URL_PATH);

if (str_starts_with($path, '/redirect-cross/')) {
    header('Location: http://localhost:'.$_SERVER['SERVER_PORT'].'/echo/v1/messages', true, 307);

    return;
}
if (str_starts_with($path, '/redirect-same/')) {
    header('Location: /echo/v1/messages', true, 307);

    return;
}
if (str_starts_with($path, '/slow/')) {
    sleep(3);
}

$received = [];
foreach (getallheaders() as $name => $value) {
    $received[strtolower($name)] = $value;
}
$text = json_encode($received, JSON_THROW_ON_ERROR);

if (str_starts_with($path, '/stream/')) {
    header('Content-Type: text/event-stream');
    $events = [
        ['message_start', ['type' => 'message_start', 'message' => ['id' => 'msg_e2e', 'type' => 'message', 'role' => 'assistant', 'model' => 'm', 'content' => [], 'stop_reason' => null, 'stop_sequence' => null, 'usage' => ['input_tokens' => 3, 'output_tokens' => 1]]]],
        ['content_block_start', ['type' => 'content_block_start', 'index' => 0, 'content_block' => ['type' => 'text', 'text' => '']]],
        ['content_block_delta', ['type' => 'content_block_delta', 'index' => 0, 'delta' => ['type' => 'text_delta', 'text' => $text]]],
        ['content_block_stop', ['type' => 'content_block_stop', 'index' => 0]],
        ['message_delta', ['type' => 'message_delta', 'delta' => ['stop_reason' => 'end_turn', 'stop_sequence' => null], 'usage' => ['output_tokens' => 4]]],
        ['message_stop', ['type' => 'message_stop']],
    ];
    foreach ($events as [$type, $payload]) {
        echo "event: $type\ndata: ".json_encode($payload, JSON_THROW_ON_ERROR)."\n\n";
    }

    return;
}

header('Content-Type: application/json');
echo json_encode([
    'id' => 'msg_e2e', 'type' => 'message', 'role' => 'assistant', 'model' => 'm',
    'content' => [['type' => 'text', 'text' => $text]],
    'stop_reason' => 'end_turn', 'stop_sequence' => null,
    'usage' => ['input_tokens' => 1, 'output_tokens' => 2],
], JSON_THROW_ON_ERROR);
