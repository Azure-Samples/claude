<?php

declare(strict_types=1);

// PHP's built-in assert() is the assertion mechanism: refuse to run where it is switched off, which would pass silently.
if ((int) ini_get('zend.assertions') < 1 || !filter_var(ini_get('assert.exception'), FILTER_VALIDATE_BOOLEAN)) {
    fwrite(STDERR, "Run with assertions enabled: php -d zend.assertions=1 -d assert.exception=1 tests/run.php\n");
    exit(2);
}

require __DIR__.'/../vendor/autoload.php';
require __DIR__.'/support.php';
foreach (['ClientFactoryTest', 'CliTokenProviderTest', 'SampleTest', 'EndToEndTest'] as $file) {
    require __DIR__."/$file.php";
}

exit(ClaudeSample\Tests\Suite::run());
