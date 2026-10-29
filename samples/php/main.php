#!/usr/bin/env php
<?php

declare(strict_types=1);

$autoload = __DIR__.'/vendor/autoload.php';
if (!is_file($autoload)) {
    fwrite(STDERR, "Run \"composer install\" in this directory first.\n");
    exit(1);
}
require $autoload;

exit(ClaudeSample\Sample::run(array_slice($argv, 1), getenv(), STDOUT, STDERR));
