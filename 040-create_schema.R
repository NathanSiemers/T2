################################################################
## create core tables

## tcga numeric data with integer keys for sample and probe
################################################################
## sequence/auto increment tables are database specific

if( mysql ) {
    print('MySQL connection')
    try(dbRemoveTable(con, 'tcgai'))
    dbCreateTable(con, name = 'tcgai', c(
                           samplekey = 'mediumint unsigned not null',
                           probekey = 'mediumint unsigned not null',
                           value = 'float not null',
                           type = 'varchar(35) not null' ) )
    try(dbRemoveTable(con, 'tcgacati'))
    dbCreateTable(con, name = 'tcgacati', c(
                           samplekey = 'mediumint unsigned not null',
                           probekey = 'mediumint unsigned not null',
                           value = 'varchar(35) not null',
                           type = 'varchar(35) not null' ) )
    try(dbRemoveTable(con, 'probes'))
    dbCreateTable(con, name = 'probes', c(
                           key = 'mediumint unsigned not null primary key auto_increment',
                           probe = 'varchar(35) unique not null'))
                           ##oprobe = 'varchar(35)' ))
    dbExecute(con, 'ALTER TABLE probes AUTO_INCREMENT = 1')
    try(dbRemoveTable(con, 'allprobes'))
    dbCreateTable(con, name = 'allprobes', c(
                           key = 'mediumint unsigned not null primary key auto_increment',
                           probe = 'varchar(35) unique not null' ) )
    dbExecute(con, 'ALTER TABLE allprobes AUTO_INCREMENT = 1')
    try(dbRemoveTable(con, 'samples'))
    dbCreateTable(con, name = 'samples', c(
                           key = 'mediumint unsigned not null primary key auto_increment',
                           sample = 'varchar(35) unique not null' ) )
    dbExecute(con, 'ALTER TABLE samples AUTO_INCREMENT = 1')
    try(dbRemoveTable(con, 'tcgaitmp'))
    dbCreateTable(con, name = 'tcgaitmp', c(
                           sample = 'varchar(35)',
                           probe = 'varchar(35)',
                           value = 'float',
                           type = 'varchar(35)' ) )
    try(dbRemoveTable(con, 'tcgacatitmp'))
    dbCreateTable(con, name = 'tcgacatitmp', c(
                           sample = 'varchar(35)',
                           probe = 'varchar(35)',
                           value = 'varchar(35) not null',
                           type = 'varchar(35)' ) )
    try(dbRemoveTable(con, 'tested'))
    dbCreateTable(con, name = 'tested', c(
      sample = 'varchar(35)',
      ##probe = 'varchar(35)',
      value = 'int',
      type = 'varchar(35)' ) )
    try(dbRemoveTable(con, 'probestmp'))
    dbCreateTable(con, name = 'probestmp', c(
                           key = 'mediumint unsigned',
                           probe = 'varchar(35)' ))
                           ##oprobe = 'varchar(35)'))
    try(dbRemoveTable(con, 'allprobestmp'))
    dbCreateTable(con, name = 'allprobestmp', c(
                           key = 'mediumint unsigned',
                           probe = 'varchar(35) not null' ) )
    try(dbRemoveTable(con, 'samplestmp'))
    dbCreateTable(con, name = 'samplestmp', c(
                           key = 'mediumint unsigned not null',
                           sample = 'varchar(35) not null' ) )
    try(dbRemoveTable(con, 'types'), silent = TRUE)
    dbCreateTable(con, name = 'types', c(
                           key = 'mediumint unsigned not null primary key auto_increment',
                           type = 'varchar(35) unique not null') )
    dbExecute(con, 'ALTER TABLE types AUTO_INCREMENT = 1')
    try(dbRemoveTable(con, 'nosuffix'), silent = TRUE)
    dbCreateTable(con, name = 'nosuffix', c(
                           type = 'varchar(35) primary key') )
    try(dbRemoveTable(con, 'datatypes'), silent = TRUE)
    dbCreateTable(con, name = 'datatypes', c(
                           type = 'varchar(35) primary key',
                           r_datatype = "varchar(15) not null default 'numeric'") )
} else {
    print('Non-MySQL connection')
    try(dbRemoveTable(con, 'tcgai'), silent = TRUE)
    dbCreateTable(con, name = 'tcgai', c(
                           samplekey = 'int',
                           probekey = 'int',
                           value = 'float',
                           type = 'character' ) )
    try(dbRemoveTable(con, 'tcgacati'), silent = TRUE)
    dbCreateTable(con, name = 'tcgacati', c(
                           samplekey = 'int',
                           probekey = 'int',
                           value = 'character',
                           type = 'character' ) )
    try(dbRemoveTable(con, 'probes'), silent = TRUE)
    dbCreateTable(con, name = 'probes', c(
                           key = 'integer primary key',
                           probe = 'character unique not null'))
                           ##oprobe = 'character') )
    try(dbRemoveTable(con, 'allprobes'), silent = TRUE)
    dbCreateTable(con, name = 'allprobes', c(
                           key = 'integer primary key',
                           probe = 'character unique not null' ) )
    try(dbRemoveTable(con, 'samples'), silent = TRUE)
    dbCreateTable(con, name = 'samples', c(
                           key = 'integer primary key',
                           sample = 'character unique not null' ) )
    try(dbRemoveTable(con, 'tcgaitmp'), silent = TRUE)
    dbCreateTable(con, name = 'tcgaitmp', c(
                           sample = 'character',
                           probe = 'character',
                           value = 'float',
                           type = 'character' ) )
    try(dbRemoveTable(con, 'tcgacatitmp'), silent = TRUE)
    dbCreateTable(con, name = 'tcgacatitmp', c(
                           sample = 'character',
                           probe = 'character',
                           value = 'character',
                           type = 'character' ) )
    try(dbRemoveTable(con, 'probestmp'), silent = TRUE)
    dbCreateTable(con, name = 'probestmp', c(
                           key = 'int',
                           probe = 'character'))
                           ##oprobe = 'character' ) )
    try(dbRemoveTable(con, 'allprobestmp'), silent = TRUE)
    dbCreateTable(con, name = 'allprobestmp', c(
                           key = 'int',
                           probe = 'character' ) )
    try(dbRemoveTable(con, 'samplestmp'), silent = TRUE)
    dbCreateTable(con, name = 'samplestmp', c(
                           key = 'int',
                           sample = 'character' ) )
    try(dbRemoveTable(con, 'types'), silent = TRUE)
    dbCreateTable(con, name = 'types', c(
                           key = 'integer primary key',
                           type = 'character unique not null') )
    try(dbRemoveTable(con, 'nosuffix'), silent = TRUE)
    dbCreateTable(con, name = 'nosuffix', c(
                           type = 'character unique not null') )
    try(dbRemoveTable(con, 'datatypes'), silent = TRUE)
    dbCreateTable(con, name = 'datatypes', c(
                           type = 'character primary key',
                           r_datatype = "character not null default 'numeric'") )
    try(dbRemoveTable(con, 'tested'))
    dbCreateTable(con, name = 'tested', c(
      sample = 'varchar(35)',
      ##probe = 'varchar(35)',
      value = 'int',
      type = 'varchar(35)' ) )
}
