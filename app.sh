R -e 'if( !require("shinycssloaders") ) install.packages("shinycssloaders")'
R -e 'if( !require("RMySQL") ) install.packages("RMySQL")'
R -e 'if( !require("pool") ) install.packages("pool")'
R -e 'shiny::runApp("./", port=8888, host="0.0.0.0")'
