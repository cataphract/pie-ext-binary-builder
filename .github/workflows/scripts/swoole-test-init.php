<?php

Swoole\Coroutine\run(static function (): void {
    swoole_library_set_option('default_remote_object_server_worker_num', 2);
    swoole_init_default_remote_object_server();
});
