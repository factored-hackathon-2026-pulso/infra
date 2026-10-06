# user_data batch and loop timer (one controlled replacement window)

Fixes in `prepare.sh.tftpl` and `user_data.sh.tftpl`, to be applied together (the instances are replaced once):

- `pulso-stack-up`: containers recreated once per boot (tmpfs marker), never on a retry; `RestartSec=60`.
- `pulso-loop.timer`: `OnUnitActiveSec` (always a next elapse); `pulso-loop.service` without `Restart=` and `StartLimitIntervalSec=0`.
- prepare fails closed on `CHANGE_ME` human-only keys and on missing compose `env_file`s; seeds `{}` as the field catalog before the first publication.

Verification: `python -m unittest discover -s tests` (514 tests, new `tests/test_userdata_batch_contract.py` written RED first), `terraform fmt -check`, `terraform test` in `hackathon_compute` (43 pass). `envs/hackathon` `wire.tftest.hcl` has two failures (agent load caps) that also fail on origin/main and are not touched here. Nothing was applied.
