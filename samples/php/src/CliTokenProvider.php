<?php

declare(strict_types=1);

namespace ClaudeSample;

/**
 * A token provider for local development that asks a command-line tool for the current token. The one built-in
 * tool is the Azure CLI, used as a documented fallback; production code passes its own provider to ClientFactory.
 *
 * Every token request starts `az account get-access-token --scope <scope> --output json`. The CLI owns token caching
 * and renewal, so the price is one CLI process per request and this class keeps no cache of its own. Production code
 * should give ClientFactory a token provider backed by its own identity library instead.
 *
 * The command is a fixed argument list, never shell text. Every argument is checked against a short allowlist, which also
 * keeps cmd.exe metacharacters out when the CLI is a Windows batch file (az.cmd / az.bat).
 *
 * Each CLI process gets a finite allowance (60 seconds: a cold start under load can exceed 10). When it runs out the
 * process (and, on Windows, its children) is stopped and the call fails; there is no fallback to another credential.
 */
final class CliTokenProvider
{
    public const TIMEOUT_SECONDS = 60.0;

    /** Letters, digits and . _ : / - only: no quotes, spaces, or shell and cmd.exe metacharacters. */
    private const SAFE_ARGUMENT = '/^[A-Za-z0-9._:\/-]+$/D';

    private const TENANT = '/^[A-Za-z0-9.-]+$/D';

    private const VISIBLE_ASCII = '/^[\x21-\x7E]+$/D';

    private function __construct() {}

    /**
     * @param (callable(list<string>): array{int, string})|null $run Replaces the process launch. Receives the arguments after `az` and returns [exit code, stdout].
     * @param float|null $timeout Seconds each CLI process may take; null means TIMEOUT_SECONDS
     *
     * @return \Closure(): string
     */
    public static function provider(string $scope, ?string $tenantId = null, ?callable $run = null, ?float $timeout = null): \Closure
    {
        $arguments = ['account', 'get-access-token', '--scope', self::safe($scope, 'The token scope'), '--output', 'json'];
        if ($tenantId !== null && '' !== $tenantId) {
            if (1 !== preg_match(self::TENANT, $tenantId)) {
                throw new \InvalidArgumentException('The tenant ID may only contain letters, digits, "." and "-".');
            }
            array_push($arguments, '--tenant', $tenantId);
        }
        $run ??= static fn (array $arguments): array => self::run($arguments, null, $timeout);

        return static function () use ($arguments, $run, $scope): string {
            [$exitCode, $stdout] = $run($arguments);
            if (0 !== $exitCode) {
                throw new \RuntimeException(sprintf('Azure CLI exited with code %d while requesting a token for scope %s. Run "az login" and retry, or supply your own token provider.', $exitCode, $scope));
            }
            try {
                $payload = json_decode($stdout, true, 16, JSON_THROW_ON_ERROR);
            } catch (\JsonException) {
                $payload = null;
            }
            if (!is_array($payload) || ([] !== $payload && array_is_list($payload))) {
                throw new \RuntimeException('Azure CLI returned output that is not a JSON object.');
            }
            $token = $payload['accessToken'] ?? null;
            if (!is_string($token) || 1 !== preg_match(self::VISIBLE_ASCII, $token)) {
                throw new \RuntimeException('Azure CLI response has no usable accessToken.');
            }

            return $token;
        };
    }

    /**
     * Starts the Azure CLI found on $searchPath (default: PATH) and returns [exit code, stdout]. stderr is discarded.
     * A CLI that is still running after $timeout seconds (default TIMEOUT_SECONDS) is stopped and the call throws.
     *
     * @param list<string> $arguments
     *
     * @return array{int, string}
     */
    public static function run(array $arguments, ?string $searchPath = null, ?float $timeout = null): array
    {
        $timeout ??= self::TIMEOUT_SECONDS;
        foreach ($arguments as $argument) {
            self::safe($argument, 'Azure CLI arguments');
        }
        $windows = 'Windows' === PHP_OS_FAMILY;
        $executable = self::locate($searchPath ?? (string) getenv('PATH'), null, $windows);
        if ($executable === null) {
            throw new \RuntimeException('Azure CLI ("az") was not found on PATH. Install it and run "az login", or supply your own token provider.');
        }
        [$command, $directory] = self::command($executable, $arguments, $windows, $windows ? self::commandInterpreter() : null);
        // Windows pipes cannot be read against a deadline; a socket pair can.
        $descriptors = [0 => ['pipe', 'r'], 1 => $windows ? ['socket'] : ['pipe', 'w'], 2 => ['file', $windows ? 'NUL' : '/dev/null', 'w']];
        $process = @proc_open($command, $descriptors, $pipes, $directory, null, ['bypass_shell' => true]);
        if (!is_resource($process)) {
            throw new \RuntimeException('Azure CLI could not be started.');
        }
        fclose($pipes[0]);

        $deadline = microtime(true) + $timeout;
        $stdout = '';
        while (true) {
            $remaining = $deadline - microtime(true);
            if ($remaining <= 0) {
                self::stop($process, $windows);
                fclose($pipes[1]);
                proc_close($process);
                throw new \RuntimeException(sprintf('Azure CLI did not finish within its %s second allowance and was stopped; try "az account get-access-token --output none" by hand, or supply your own token provider.', rtrim(rtrim(number_format($timeout, 1, '.', ''), '0'), '.')));
            }
            $stdout .= self::available($pipes[1], min(0.2, $remaining));
            $status = proc_get_status($process);
            if (!$status['running']) {
                // The exit code is only reported by the first status call after the process ended.
                $exitCode = $status['exitcode'] < 0 ? 1 : $status['exitcode'];
                break;
            }
            if (feof($pipes[1])) {
                usleep(10_000);
            }
        }
        $stdout .= self::available($pipes[1], 0.05, true);
        fclose($pipes[1]);
        proc_close($process);

        return [$exitCode, $stdout];
    }

    /**
     * Finds `az` in the absolute directories of $searchPath. On Windows it honors PATHEXT, limited to .com, .exe, .bat and .cmd.
     */
    public static function locate(string $searchPath, ?string $pathExt = null, ?bool $windows = null): ?string
    {
        $windows ??= 'Windows' === PHP_OS_FAMILY;
        $names = ['az'];
        if ($windows) {
            $extensions = array_values(array_filter(
                array_map('strtolower', explode(';', $pathExt ?? (string) getenv('PATHEXT'))),
                static fn (string $extension): bool => in_array($extension, ['.com', '.exe', '.bat', '.cmd'], true),
            ));
            $names = array_map(static fn (string $extension): string => 'az'.$extension, $extensions ?: ['.com', '.exe', '.bat', '.cmd']);
        }
        foreach (explode($windows ? ';' : ':', $searchPath) as $directory) {
            $directory = trim($directory, " \t\"");
            $absolute = $windows ? 1 === preg_match('/^(?:[A-Za-z]:[\\\\\/]|\\\\\\\\)/', $directory) : str_starts_with($directory, '/');
            if (!$absolute) {
                continue;
            }
            foreach ($names as $name) {
                $candidate = rtrim($directory, '\\/').DIRECTORY_SEPARATOR.$name;
                if (is_file($candidate) && ($windows || is_executable($candidate))) {
                    return $candidate;
                }
            }
        }

        return null;
    }

    /**
     * Builds the argument list and working directory for one launch.
     *
     * A Windows batch file can only run under cmd.exe. It is started by bare file name from its own directory, so a
     * path with spaces or parentheses needs no quoting; /d skips AutoRun commands. Arguments are allowlisted by run().
     *
     * @param list<string> $arguments
     *
     * @return array{list<string>, string|null} [argv, working directory]
     */
    public static function command(string $executable, array $arguments, bool $windows, ?string $interpreter = null): array
    {
        if ($windows && 1 === preg_match('/\.(?:bat|cmd)$/i', $executable)) {
            return [[$interpreter ?? self::commandInterpreter(), '/d', '/c', basename($executable), ...$arguments], dirname($executable)];
        }

        return [[$executable, ...$arguments], null];
    }

    /** What $stream can deliver within $wait seconds; with $all, everything that is already there. */
    private static function available($stream, float $wait, bool $all = false): string
    {
        $data = '';
        do {
            $read = [$stream];
            $write = $except = null;
            if (!@stream_select($read, $write, $except, 0, (int) ($wait * 1_000_000)) || [] === $read) {
                break;
            }
            $chunk = fread($stream, 8192);
            if (!is_string($chunk) || '' === $chunk) {
                break;
            }
            $data .= $chunk;
        } while ($all);

        return $data;
    }

    /** Stops the CLI; on Windows also its children (az.cmd runs the CLI as a child of cmd.exe). */
    private static function stop($process, bool $windows): void
    {
        $pid = (int) (proc_get_status($process)['pid'] ?? 0);
        if ($windows && $pid > 0) {
            $taskkill = rtrim((string) (getenv('SystemRoot') ?: 'C:\\Windows'), '\\/').'\\System32\\taskkill.exe';
            $killer = @proc_open([$taskkill, '/F', '/T', '/PID', (string) $pid], [0 => ['file', 'NUL', 'r'], 1 => ['file', 'NUL', 'w'], 2 => ['file', 'NUL', 'w']], $ignored, null, null, ['bypass_shell' => true]);
            if (is_resource($killer)) {
                proc_close($killer);
            }
        }
        proc_terminate($process, 9);
    }

    private static function commandInterpreter(): string
    {
        $configured = (string) getenv('ComSpec');
        if (0 === strcasecmp(basename($configured), 'cmd.exe') && is_file($configured)) {
            return $configured;
        }

        return rtrim((string) (getenv('SystemRoot') ?: 'C:\\Windows'), '\\/').'\\System32\\cmd.exe';
    }

    private static function safe(string $value, string $what): string
    {
        if (1 !== preg_match(self::SAFE_ARGUMENT, $value)) {
            throw new \InvalidArgumentException(sprintf('%s may only contain letters, digits and the characters . _ : / -', $what));
        }

        return $value;
    }
}
