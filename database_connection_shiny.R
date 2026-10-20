## database_connection_shiny.R
## The Shiny app opens no database: its data layer is the t2api service (t2_api_client.R,
## T2_API_URL). This file stays only so that scripts which still source it keep working.
if (!exists("t2_cache")) source("t2_util.R")
source("t2_api_client.R")
