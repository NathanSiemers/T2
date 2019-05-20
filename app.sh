R -e 'install.packages("shinycssloaders")'
R -e 'install.packages("RMySQL")'
R -e 'shiny::runApp("./", port=8888, host="0.0.0.0")'
