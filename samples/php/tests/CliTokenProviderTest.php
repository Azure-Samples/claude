<?php

declare(strict_types=1);

namespace ClaudeSample\Tests;

use ClaudeSample\CliTokenProvider;

const FAKE_AZ_DIRECTORY = __DIR__.DIRECTORY_SEPARATOR.'fixtures'.DIRECTORY_SEPARATOR.'fake-az';
const TOKEN_ARGUMENTS = ['account', 'get-access-token', '--scope', 'https://ai.azure.com/.default', '--output', 'json'];

/** @return \Closure(list<string>): array{int, string} */
function cli_returning(int $exitCode, string $stdout, array &$calls = []): \Closure
{
    return static function (array $arguments) use ($exitCode, $stdout, &$calls): array {
        $calls[] = $arguments;

        return [$exitCode, $stdout];
    };
}

function failure_message(\Closure $provider): string
{
    try {
        $provider();
    } catch (\RuntimeException $error) {
        return $error->getMessage();
    }
    throw new \AssertionError('the provider succeeded');
}

test('CLI token provider asks for the scope with a fixed argument list, once per token request', function (): void {
    $calls = [];
    $provider = CliTokenProvider::provider('https://ai.azure.com/.default', null, static function (array $arguments) use (&$calls): array {
        $calls[] = $arguments;

        return [0, json_encode(['accessToken' => 'cli-token-'.count($calls), 'expiresOn' => '2099-01-01 00:00:00.000000', 'tokenType' => 'Bearer'])];
    });
    same([], $calls, 'nothing runs at creation');
    same('cli-token-1', $provider(), 'first token');
    same('cli-token-2', $provider(), 'second token: this class keeps no cache of its own');
    same([TOKEN_ARGUMENTS, TOKEN_ARGUMENTS], $calls, 'arguments');
});

test('CLI token provider adds --tenant only when a tenant is configured', function (): void {
    $calls = [];
    CliTokenProvider::provider('https://ai.azure.com/.default', 'tenant-1.example', cli_returning(0, '{"accessToken":"t"}', $calls))();
    CliTokenProvider::provider('https://ai.azure.com/.default', '', cli_returning(0, '{"accessToken":"t"}', $calls))();
    same([[...TOKEN_ARGUMENTS, '--tenant', 'tenant-1.example'], TOKEN_ARGUMENTS], $calls, 'arguments');
});

test('CLI arguments are allowlisted, so nothing is interpreted by a shell or cmd.exe', function (): void {
    $unsafe = ['', 'a b', 'a&b', 'a|b', 'a^b', 'a%PATH%', 'a"b', "a'b", 'a;b', 'a`b', 'a$b', 'a(b)', 'a<b', "a\nb", 'a\\b'];
    foreach ($unsafe as $value) {
        foreach ([
            'scope' => static fn () => CliTokenProvider::provider($value),
            'tenant' => static fn () => CliTokenProvider::provider('https://ai.azure.com/.default', $value ?: 'x y'),
            'run' => static fn () => CliTokenProvider::run(['account', $value]),
        ] as $where => $attempt) {
            try {
                $attempt();
            } catch (\InvalidArgumentException) {
                continue;
            }
            throw new \AssertionError(sprintf('%s accepted %s', $where, json_encode($value)));
        }
    }
});

test('CLI failure, malformed output and empty tokens raise exact errors without echoing the payload', function (): void {
    $scope = 'https://ai.azure.com/.default';
    $leak = 'raw-payload-secret-value';
    $cases = [
        'non-zero exit' => [7, '{"accessToken":"'.$leak.'"}', sprintf('Azure CLI exited with code 7 while requesting a token for scope %s. Run "az login" and retry, or supply your own token provider.', $scope)],
        'not JSON' => [0, 'ERROR '.$leak, 'Azure CLI returned output that is not a JSON object.'],
        'JSON scalar' => [0, '"'.$leak.'"', 'Azure CLI returned output that is not a JSON object.'],
        'no accessToken' => [0, '{"refreshToken":"'.$leak.'"}', 'Azure CLI response has no usable accessToken.'],
        'empty accessToken' => [0, '{"accessToken":"","refreshToken":"'.$leak.'"}', 'Azure CLI response has no usable accessToken.'],
        'null accessToken' => [0, '{"accessToken":null,"x":"'.$leak.'"}', 'Azure CLI response has no usable accessToken.'],
        'numeric accessToken' => [0, '{"accessToken":12345,"x":"'.$leak.'"}', 'Azure CLI response has no usable accessToken.'],
        'spaced accessToken' => [0, '{"accessToken":"two words","x":"'.$leak.'"}', 'Azure CLI response has no usable accessToken.'],
        'multi-line accessToken' => [0, '{"accessToken":"line\nbreak","x":"'.$leak.'"}', 'Azure CLI response has no usable accessToken.'],
    ];
    foreach ($cases as $label => [$exitCode, $stdout, $expected]) {
        $message = failure_message(CliTokenProvider::provider($scope, null, cli_returning($exitCode, $stdout)));
        same($expected, $message, $label);
        assert(!str_contains($message, $leak), "$label echoed the CLI payload");
    }
});

test('a CLI that does not finish within its allowance is stopped and reported, never replaced by a fallback', function (): void {
    if ('Windows' !== PHP_OS_FAMILY) {
        chmod(FAKE_AZ_DIRECTORY.'/az', 0755);
    }
    same(60.0, CliTokenProvider::TIMEOUT_SECONDS, 'the default allowance is finite and generous');
    $started = microtime(true);
    $provider = CliTokenProvider::provider('https://ai.azure.com/.default', null, static fn (array $arguments): array => CliTokenProvider::run($arguments, FAKE_AZ_DIRECTORY, 1.0));
    $message = with_env(['FAKE_AZ_MODE' => 'slow'], static fn (): string => failure_message($provider));
    same('Azure CLI did not finish within its 1 second allowance and was stopped; try "az account get-access-token --output none" by hand, or supply your own token provider.', $message, 'message');
    assert(microtime(true) - $started < 4.5, 'the CLI must be stopped at its allowance, not left to finish (the fixture takes about 7 seconds)');
    assert(!str_contains($message, 'too-late-token'), 'no output of the CLI in the error');
});

test('a missing Azure CLI is reported with an actionable message', function (): void {
    try {
        CliTokenProvider::run(['version'], __DIR__.DIRECTORY_SEPARATOR.'no-such-directory');
    } catch (\RuntimeException $error) {
        same('Azure CLI ("az") was not found on PATH. Install it and run "az login", or supply your own token provider.', $error->getMessage(), 'message');

        return;
    }
    throw new \AssertionError('a missing CLI was not reported');
});

test('command(): a Windows batch file runs under cmd.exe from its own directory, anything else runs directly', function (): void {
    $arguments = ['account', 'get-access-token'];
    same(
        [['C:/Windows/System32/cmd.exe', '/d', '/c', 'az.cmd', ...$arguments], 'C:/Program Files (x86)/Azure CLI/wbin'],
        CliTokenProvider::command('C:/Program Files (x86)/Azure CLI/wbin/az.cmd', $arguments, true, 'C:/Windows/System32/cmd.exe'),
        'az.cmd on Windows',
    );
    same(
        [['C:/Windows/System32/cmd.exe', '/d', '/c', 'az.BAT', ...$arguments], 'C:/tools'],
        CliTokenProvider::command('C:/tools/az.BAT', $arguments, true, 'C:/Windows/System32/cmd.exe'),
        'az.BAT on Windows',
    );
    same([['C:/tools/az.exe', ...$arguments], null], CliTokenProvider::command('C:/tools/az.exe', $arguments, true, 'C:/Windows/System32/cmd.exe'), 'az.exe on Windows');
    same([['/usr/bin/az', ...$arguments], null], CliTokenProvider::command('/usr/bin/az', $arguments, false), 'az on Unix');
    same([['/opt/tools/az.cmd', ...$arguments], null], CliTokenProvider::command('/opt/tools/az.cmd', $arguments, false), 'a file named az.cmd on Unix is not special');
});

test('locate(): searches only absolute PATH entries and honors PATHEXT on Windows', function (): void {
    $directory = FAKE_AZ_DIRECTORY;
    if ('Windows' === PHP_OS_FAMILY) {
        same($directory.'\\az.cmd', CliTokenProvider::locate($directory, '.COM;.EXE;.BAT;.CMD', true), 'found through PATHEXT');
        same($directory.'\\az.cmd', CliTokenProvider::locate('relative-dir;'.$directory, null, true), 'relative PATH entries are skipped; default extensions');
        same(null, CliTokenProvider::locate('relative-dir;'.__DIR__.'\\nowhere', '.EXE', true), 'absent');
        same(null, CliTokenProvider::locate($directory, '.EXE;.COM', true), 'extensions missing from PATHEXT are not tried');
    } else {
        chmod($directory.'/az', 0755);
        same($directory.'/az', CliTokenProvider::locate('relative-dir:'.$directory, null, false), 'found on PATH');
        same(null, CliTokenProvider::locate('relative-dir', null, false), 'relative PATH entries are skipped');
    }
});

test('real process launch: the fixture CLI receives exactly the fixed arguments and its exit status is returned', function (): void {
    if ('Windows' !== PHP_OS_FAMILY) {
        chmod(FAKE_AZ_DIRECTORY.'/az', 0755);
    }
    $run = static fn (array $arguments): array => CliTokenProvider::run($arguments, FAKE_AZ_DIRECTORY);

    [$exitCode, $stdout] = with_env(['FAKE_AZ_MODE' => 'args'], static fn (): array => $run([...TOKEN_ARGUMENTS, '--tenant', 'tenant-1.example']));
    same(0, $exitCode, 'exit code');
    same(
        'account get-access-token --scope https://ai.azure.com/.default --output json --tenant tenant-1.example',
        json_decode($stdout, true, flags: JSON_THROW_ON_ERROR)['accessToken'],
        'arguments as the CLI saw them',
    );

    $token = with_env(['FAKE_AZ_MODE' => 'ok'], static fn (): string => CliTokenProvider::provider('https://ai.azure.com/.default', null, $run)());
    same('fixture-cli-token', $token, 'token through the provider');

    same(3, with_env(['FAKE_AZ_MODE' => 'fail'], static fn (): int => $run(TOKEN_ARGUMENTS)[0]), 'failing CLI exit code');
    $message = with_env(['FAKE_AZ_MODE' => 'empty'], static fn (): string => failure_message(CliTokenProvider::provider('https://ai.azure.com/.default', null, $run)));
    same('Azure CLI response has no usable accessToken.', $message, 'empty token through a real launch');
});
