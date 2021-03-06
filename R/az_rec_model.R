#' Azure product recommendations model class
#'
#' Class representing an individual product recommendations (SAR) model.
#'
#' @docType class
#' @section Methods:
#' - `new(...)`: Initialize a model object. See 'Initialization' for more details.
#' - `delete(confirm=TRUE)`: Delete the model.
#' - `user_predict(userdata, k=10)`: Get personalised recommendations from the model. See 'Recommendations' for more details.
#' - `item_predict(item, k=10)`: Get item-to-item recommendations from the model. See 'Recommendations' for more details.
#' - `get_model_url()`: Get the individual service URL for this model.
#'
#' @section Initialization:
#' Generally, the easiest way to initialize a new model object is via the `get_model()` and `train_model()` methods of the `rec_endpoint` class, which will handle all the gory details.
#'
#' @section Recommendations:
#' These arguments are used for obtaining personalised and item-to-item recommendations.
#' - `userdata`: The input data on users for which to obtain personalised recommendations. This can be:
#'    1. A character vector of user IDs. In this case, personalised recommendations will be computed based on the transactions in the training data, _ignoring_ any transaction event IDs or weights.
#'    2. A data frame containing transaction item IDs, event types and/or weights, plus timestamps. In this case, all the transactions are assumed to be for a single (new) user. If the event types/weights are absent, all transactions are assigned equal weight.
#'    3. A data frame containing user IDs and transaction details as in (2). In this case, the recommendations are based on both the training data for the given user(s), plus the new transaction details.
#' - `item`: A vector of item IDs for which to obtain item-to-item recommendations.
#' - `k`: The number of recommendations to return. Defaults to 10.
#'
#' Both the `user_predict()` and `item_predict()` methods return a data frame with the top-K recommendations and scores.
#'
#' @seealso
#' [az_rec_service] for the service backend, [rec_endpoint] for the client endpoint
#'
#' [API reference](https://github.com/Microsoft/Product-Recommendations/blob/master/doc/api-reference.md) and [SAR model description](https://github.com/Microsoft/Product-Recommendations/blob/master/doc/sar.md) at the Product Recommendations API repo on GitHub
#'
#' @examples
#' \dontrun{
#'
#' # get a recommender endpoint and previously-trained model
#' rec_endp <- rec_endpoint$new("myrecusacvjwpk4raost", admin_key="key1", rec_key="key2")
#' rec_model <- rec_endp$get_model("model1")
#'
#' data(ms_usage)
#'
#' # item recommendations for a set of user IDs
#' users <- unique(ms_usage$user)[1:5]
#' rec_model$user_predict(users)
#'
#' # item recommendations for a set of user IDs and transactions (assumed to be new)
#' user_df <- subset(ms_usage, user %in% users)
#' rec_model$user_predict(user_df)
#'
#' # item recomendations for a set of item IDs
#' items <- unique(ms_usage$item)[1:5]
#' rec_model$item_predict(items)
#'
#' }
#' @format An R6 object of class `rec_model`.
#' @export
rec_model <- R6Class("rec_model",

public=list(
    service_url=NULL,
    admin_key=NULL,
    rec_key=NULL,
    id=NULL,
    description=NULL,
    creation_time=NULL,
    status=NULL,
    status_message=NULL,
    parameters=NULL,
    stats=NULL,

    initialize=function(service_url, admin_key, rec_key, id, ..., parms=list(...), wait=TRUE)
    {
        self$service_url <- service_url
        self$admin_key <- admin_key
        self$rec_key <- rec_key

        if(is_empty(parms))
        {
            self$id <- id
            parms <- private$get_model()
            self$description <- parms$description
        }
        else
        {
            self$description <- parms$description
            parms <- private$train_model(parms, wait=wait)
        }

        self$creation_time <- as.POSIXct(parms$creationTime, format="%Y-%m-%dT%H:%M:%OS", tz="GMT")
        self$status <- parms$modelStatus
        self$status_message <- parms$modelStatusMessage
        self$parameters <- parms$parameters
        self$stats <- parms$statistics
    },

    delete=function(confirm=TRUE)
    {
        if(confirm && interactive())
        {
            yn <- readline(paste0("Do you really want to delete model '", self$description, "'? (y/N) "))
            if(tolower(substr(yn, 1, 1)) != "y")
                return(invisible(NULL))
        }
        message("Deleting model '", self$description, "'")
        private$model_op(http_verb="DELETE")
    },

    user_predict=function(userdata=NULL, k=10)
    {
        # assume userdata in fixed format
        if(is.data.frame(userdata))
        {
            users <- as.character(userdata$user)
            user_col <- which(names(userdata) == "user")
        }
        else users <- as.character(userdata)

        userid_provided <- length(users) > 0
        if(!userid_provided && !is.data.frame(userdata))
            stop("Must provide user IDs or transaction events to get recommendations for", call.=FALSE)

        users <- unique(users)
        n_users <- max(1, length(users))
        result <- lapply(seq_len(n_users), function(i)
        {
            # wrangle any provided dataset into format the API can accept
            if(is.data.frame(userdata) && "item" %in% names(userdata))
            {
                if(userid_provided)
                    data_i <- userdata[userdata$user == users[i], - user_col, drop=FALSE]
                else data_i <- userdata

                # rename to match API conventions
                names(data_i)[names(data_i) == "item"] <- "itemId"
                names(data_i)[names(data_i) == "time"] <- "timestamp"
                names(data_i)[names(data_i) == "event"] <- "eventType"
            }
            else data_i <- NULL

            options <- list(recommendationCount=k)
            if(userid_provided)
                options <- c(options, userId=users[i])

            private$model_op("recommend", body=data_i, encode="json", options=options,
                             key=self$rec_key,
                             http_verb="POST")
        })

        # pad out number of recommendations for each user with NAs, if we are short
        result <- lapply(result, function(row)
        {
            df <- dplyr::bind_cols(row)
            nc <- ncol(df)
            if(nc < 2 * k)
                df[(nc + 1):(2 * k)] <- list(NA_character_, NA_real_)
            df
        }) %>% dplyr::bind_rows()
        names(result) <- paste0(c("rec", "score"), rep(seq_len(k), each=2))

        # reorder columns to match standalone predict
        perm <- c(matrix(seq_len(k * 2), ncol=2, byrow=TRUE))
        result <- result[perm]

        if(userid_provided)
            result <- dplyr::bind_cols(user=users, result)
        as.data.frame(result)
    },

    item_predict=function(item=NULL, k=10)
    {
        if(is.null(item))
            stop("Must provide item IDs to get recommendations for", call.=FALSE)
        if(is.data.frame(item))
            item <- item$item

        item <- unique(item)
        n_items <- length(item)
        result <- lapply(seq_len(n_items), function(i)
        {
            options <- list(itemId=item[i], recommendationCount=k)
            private$model_op("recommend", options=options, key=self$rec_key)
        })

        # pad out number of recommendations for each user with NAs, if we are short
        result <- lapply(result, function(row)
        {
            df <- dplyr::bind_cols(row)
            nc <- ncol(df)
            if(nc < 2 * k)
                df[(nc + 1):(2 * k)] <- list(NA_character_, NA_real_)
            df
        }) %>% dplyr::bind_rows()
        names(result) <- paste0(c("rec", "score"), rep(seq_len(k), each=2))

        result <- dplyr::bind_cols(item=item, result)

        # reorder columns to match standalone predict
        perm <- c(matrix(seq_len(k * 2), ncol=2, byrow=TRUE)) + 1
        as.data.frame(result[c(1, perm)])
    },

    get_model_url=function()
    {
        paste0(self$service_url, "/api/models/", self$id)
    },

    print=function(...)
    {
        cat("Description:", self$description, "\n")
        cat("Endpoint:", self$get_model_url(), "\n")
        cat("Creation time:", format(self$creation_time, usetz=TRUE), "\n")
        cat("Status:", self$status, "\n")

        parms <- self$parameters
        class(parms) <- "simple.list"
        cat("\nModel training parameters:\n")
        print(parms, ...)

        if(!is.null(self$stats))
        {
            stats <- self$stats
            stats <- list("Training duration"=stats$trainingDuration,
                          "Total duration"=stats$totalDuration,
                          "Included events"=stats$usageEventsParsing$successfulLinesCount,
                          "Total events"=stats$usageEventsParsingtotalLinesCount,
                          "Item count"=stats$numberOfUsageItems,
                          "User count"=stats$numberOfUsers
            )
            class(stats) <- "simple.list"
            cat("\nTraining statistics:\n")
            print(stats)

            ev <- stats$evaluation
            if(!is.null(ev))
            {
                evalstats <- list("Evaluation duration"=ev$duration,
                                  "Total evaluation events"=ev$usageEventsParsing$totalLinesCount,
                                  "Included evaluation events"=ev$usageEventsParsing$successfulLinesCount)
                class(evalstats) <- "simple.list"
                cat("\nEvaluation statistics:\n")
                print(evalstats)

                divstats <- list("Total items recommended"=ev$metrics$diversityMetrics$totalItemsRecommended,
                                 "Unique items recommended"=ev$metrics$diversityMetrics$uniqueItemsRecommended,
                                 "Unique items in training set"=ev$metrics$diversityMetrics$uniqueItemsInTrainSet)
                class(divstats) <- "simple.list"
                cat("\nDiversity metrics:\n")
                print(divstats)
                cat("\n")
                div <- as.data.frame(dplyr::bind_rows(ev$metrics$diversityMetrics$percentileBuckets))
                print(div)

                cat("\nPrecision metrics:\n")
                prec <- as.data.frame(dplyr::bind_rows(ev$metrics$precisionMetrics))
                print(prec)
            }
        }
        invisible(NULL)
    }
),

private=list(

    get_model=function()
    {
        private$model_op()
    },

    train_model=function(parms, wait)
    {
        fit_args <- parms[!sapply(parms, is.null)]
        res <- private$model_op(body=fit_args, encode="json", http_verb="POST")
        self$id <- res$id

        if(wait)
        {
            for(i in 1:1000)
            {
                message(".", appendLF=FALSE)
                status <- res$modelStatus
                if(status == "Completed")
                    break
                Sys.sleep(5)
                res <- private$model_op()
            }
            if(status != "Completed")
                warning("\nTimed out waiting for model training to complete")
            else message("\nTraining complete")
        }
        res
    },

    model_op=function(op="", ..., options=list(), headers=list(),
                      key=self$admin_key,
                      http_verb=c("GET", "PUT", "POST", "DELETE", "HEAD"))
    {
        url <- httr::parse_url(self$get_model_url())
        url$path <- paste0(url$path, "/", op)
        url$query <- options
        headers <- httr::add_headers("x-api-key"=key, .headers=unlist(headers))

        # call recommender service backend
        verb <- get(match.arg(http_verb), getNamespace("httr"))

        cont <- verb(url, ..., headers)
        httr::stop_for_status(cont)
        httr::content(cont)
    }
))



