################################################################
## Enrich the types table with descriptions, examples, and references

source('type_descriptions.R')

## add columns to types table if they don't exist
existing_cols = dbListFields(con, 'types')
if (!'description' %in% existing_cols) {
  dbExecute(con, 'ALTER TABLE types ADD COLUMN description TEXT DEFAULT ""')
}
if (!'example' %in% existing_cols) {
  dbExecute(con, 'ALTER TABLE types ADD COLUMN example TEXT DEFAULT ""')
}
if (!'reference' %in% existing_cols) {
  dbExecute(con, 'ALTER TABLE types ADD COLUMN reference TEXT DEFAULT ""')
}
if (!'source_url' %in% existing_cols) {
  dbExecute(con, 'ALTER TABLE types ADD COLUMN source_url TEXT DEFAULT ""')
}
if (!'source_file' %in% existing_cols) {
  dbExecute(con, 'ALTER TABLE types ADD COLUMN source_file TEXT DEFAULT ""')
}

## update each type with its description
for (i in seq_len(nrow(type_info))) {
  dbExecute(con, sprintf(
    'UPDATE types SET description = %s, example = %s, reference = %s, source_url = %s, source_file = %s WHERE type = %s',
    dbQuoteString(con, type_info$description[i]),
    dbQuoteString(con, type_info$example[i]),
    dbQuoteString(con, type_info$reference[i]),
    dbQuoteString(con, type_info$source_url[i]),
    dbQuoteString(con, type_info$source_file[i]),
    dbQuoteString(con, type_info$type[i])
  ))
}

cat("Type descriptions updated:\n")
print(dbGetQuery(con, 'SELECT type, substr(description, 1, 50) as description FROM types'))
