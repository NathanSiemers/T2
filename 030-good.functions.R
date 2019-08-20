library(tidyverse)
library(sqldf)
source('tablemaker.R')

if( TESTING ) {
    my.limit = TESTINGLINES
} else {
    my.limit = Inf
}    


Q = function( query ){
    as_tibble(do.call(dbGetQuery, list( con = con, statement = query ) ))
}

ignore = function(mysql) {
    if (mysql) {
        return ( ' IGNORE ' )
    } else {
        return ( ' OR IGNORE ')
    }
}

indextable = function(mytable, mysql) {
    if(mysql){
        return(paste( "ON", mytable ) )
    } else {
        return("")
    }
}

qwc = function(...) { as.character( unlist( as.list( match.call() )[ -1 ] ) ) }


