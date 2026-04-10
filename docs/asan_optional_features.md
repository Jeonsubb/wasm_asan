| Feature | Baseline | mem1 | Match |
| --- | --- | --- | --- |
| use-after-return (`-fsanitize-address-use-after-return=always`) | stack-use-after-return | stack-use-after-return | YES |
| initialization-order (`ASAN_OPTIONS=check_initialization_order=1`) | passthrough | passthrough | YES |
