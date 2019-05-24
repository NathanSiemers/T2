R -e 'if( !require("shinycssloaders") ) install.packages("shinycssloaders")'
R -e 'if( !require("RMySQL") ) install.packages("RMySQL")'
R -e 'shiny::runApp("./", port=8888, host="0.0.0.0")'
