# `touch` only bumps updated_at; recording it would bury real changes.
PaperTrail.config.has_paper_trail_defaults = { on: %i[create update destroy] }
