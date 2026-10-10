## t2_contact.R
## ============================================================================
## "Contact the author" on the About tab: the same message path as the iPhone
## app -- POST /v1/contact of the t2api service (T2Mobile/docs/API.md), which
## appends the message to a file on the host; no mail credentials anywhere
## near the app. The service takes the sender's address from X-Forwarded-For,
## so its per-address limits apply to the visitor, not to the app container.
##
## T2_CONTACT_URL names the endpoint; unset, it is <T2_API_URL>/v1/contact, or
## nothing (then the form is not shown). On the server the app containers
## reach the service as http://t2api:8080 on the shinypublic network.
## ============================================================================
T2_CONTACT_URL = Sys.getenv("T2_CONTACT_URL", if (nzchar(Sys.getenv("T2_API_URL", ""))) paste0(sub("/+$", "", Sys.getenv("T2_API_URL")), "/v1/contact") else "")

.t2_inline = function(x) shiny::div(style = "display: inline-block; vertical-align: top; margin-right: 12px;", x)
contact_ui = function() {
  if (!nzchar(T2_CONTACT_URL)) return(NULL)
  shiny::tagList(
    shiny::h4("Contact the author"),
    shiny::helpText("A question, a problem, a request: it goes to the author of T2 only. ",
                    "Your name, address, affiliation and message are kept; nothing else."),
    shiny::div(
      .t2_inline(shiny::textInput("contact_name", "Name", width = "220px")),
      .t2_inline(shiny::textInput("contact_email", "Email", width = "260px")),
      .t2_inline(shiny::textInput("contact_affiliation", "Affiliation (optional)", width = "300px"))),
    shiny::textAreaInput("contact_message", "Message", width = "100%", rows = 5),
    shiny::actionButton("contact_send", "Send"),
    shiny::span(style = "margin-left: 12px;", shiny::textOutput("contact_status", inline = TRUE)))
}

## the sender's address as our own Nginx states it: X-Real-IP (set by replacement,
## so a visitor cannot forge it), else the LAST X-Forwarded-For entry (the one our
## proxy appended; the first entries are whatever the client sent), else the peer
.t2_client_ip = function(session) {
  r = session$request
  real = r$HTTP_X_REAL_IP
  if (!is.null(real) && nzchar(real)) return(trimws(real))
  xff = r$HTTP_X_FORWARDED_FOR
  if (!is.null(xff) && nzchar(xff)) { parts = trimws(strsplit(xff, ",")[[1]]); return(parts[length(parts)]) }
  r$REMOTE_ADDR %||% ""
}

## send one message; returns what to show the user
t2_contact_send = function(fields, started, session) {
  body = list(name = trimws(fields$name %||% ""), email = trimws(fields$email %||% ""),
              affiliation = trimws(fields$affiliation %||% ""), message = fields$message %||% "",
              started = as.numeric(started), app = "T2 website", website = "")
  if (!nzchar(body$name) || !nzchar(body$email) || !nzchar(trimws(body$message)))
    return("Please give your name, your email address and a message.")
  h = curl::new_handle(customrequest = "POST", postfields = jsonlite::toJSON(body, auto_unbox = TRUE), connecttimeout = 10, timeout = 30)
  curl::handle_setheaders(h, "Content-Type" = "application/json", "X-Real-IP" = .t2_client_ip(session))
  r = tryCatch(curl::curl_fetch_memory(T2_CONTACT_URL, handle = h), error = function(e) NULL)
  if (is.null(r)) return("The message could not be sent (the service did not answer). Please try again later.")
  if (r$status_code == 200) return("Thank you. Your message has been sent.")
  if (r$status_code == 429) return("Too many messages from your address; please try again later.")
  msg = tryCatch(jsonlite::fromJSON(rawToChar(r$content))$error, error = function(e) NULL)
  paste0("The message was not accepted", if (!is.null(msg)) paste0(": ", msg) else ".")
}

## the server side: wire the button to the service
contact_server = function(input, output, session) {
  if (!nzchar(T2_CONTACT_URL)) return(invisible())
  started = Sys.time()
  status = shiny::reactiveVal("")
  last_sent = NULL      # one message a minute per session: the Shiny path bypasses Nginx's per-address limit
  shiny::observeEvent(input$contact_send, {
    if (!is.null(last_sent) && as.numeric(Sys.time() - last_sent, units = "secs") < 60) {
      status("Please wait a minute before sending another message."); return()
    }
    last_sent <<- Sys.time()
    status(t2_contact_send(list(name = input$contact_name, email = input$contact_email,
                                affiliation = input$contact_affiliation, message = input$contact_message),
                           as.numeric(Sys.time() - started, units = "secs"), session))
    if (startsWith(status(), "Thank")) shiny::updateTextAreaInput(session, "contact_message", value = "")
  })
  output$contact_status = shiny::renderText(status())
}
