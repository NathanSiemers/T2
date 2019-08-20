## clinical columns can be used as probes, need to be registered into allprobes

allprobe = data.frame(
    key = NA,
    probe = colnames(dbGetQuery(con, 'select * from clin limit 1'))
    )
dbWriteTable(con, 'allprobes', allprobe, append = TRUE, row.names = FALSE)

