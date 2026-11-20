EXTENSION = quick_sync
DATA = sql/quick_sync--0.1.0.sql

PG_CONFIG = pg_config
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)