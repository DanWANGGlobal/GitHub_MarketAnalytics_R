#!/usr/bin/env Rscript
# Cloud-Ready Market Analytics Script - 最终稳定版
# 修复了NA处理和空值检查

# =============================================================================
# Environment Setup
# =============================================================================

WORK_DIR <- Sys.getenv("WORK_DIR", getwd())
INPUT_DIR <- file.path(WORK_DIR, "input")
OUTPUT_DIR <- file.path(WORK_DIR, "output")
DATA_ANALYSIS_DIR <- file.path(OUTPUT_DIR, "dataAnalysis")
CHARTING_DIR <- file.path(OUTPUT_DIR, "charting", "0html_ChartsPac")

for (dir in c(OUTPUT_DIR, DATA_ANALYSIS_DIR, CHARTING_DIR)) {
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE, showWarnings = FALSE)
}
setwd(WORK_DIR)

# =============================================================================
# Package Management
# =============================================================================

message("Loading packages...")

packages <- c("quantmod", "xts", "openxlsx", "dplyr", "plotly", "htmltools", "htmlwidgets", "TTR", "lubridate", "zoo")

for (pkg in packages) {
  if (!require(pkg, character.only = TRUE, quietly = TRUE)) {
    message(paste("Installing", pkg))
    install.packages(pkg, repos = "https://cloud.r-project.org/", quiet = TRUE)
    library(pkg, character.only = TRUE)
  }
}

message("Packages loaded!")

# =============================================================================
# Parameters
# =============================================================================

dataHistory <- 10
eDate <- Sys.Date()
sDate <- eDate - years(dataHistory)

maParameters <- c(5, 21, 89, 144)
VolCalWindow <- 20
ATRCalWindow <- 6
VaRCalWindow <- 750
RollWindow <- 180
ChgPeriod <- c(5, 20, 60, 120, 180, 250)

dataCheck <- 300

head <- "TraderX-Flow-Cloud"
source_annotation <- list(
  x = 0, y = 0.01,
  text = "Cloud Analytics | GitHub Actions",
  showarrow = FALSE,
  xref = 'paper', yref = 'paper',
  xanchor = 'left', yanchor = 'auto',
  font = list(size = 10, color = "black")
)

# =============================================================================
# Helper Functions
# =============================================================================

xts_to_tbl <- function(xts_data) {
  df <- as.data.frame(xts_data)
  df$Date <- index(xts_data)
  rownames(df) <- NULL
  return(as_tibble(df))
}

pct_rank <- function(x) {
  if (all(is.na(x))) return(rep(NA, length(x)))
  rank(x, na.last = "keep") / sum(!is.na(x))
}

run_pct_rank <- function(x, n, cumulative = FALSE) {
  if (cumulative) {
    sapply(1:length(x), function(i) {
      if (i == 1 || all(is.na(x[1:i]))) return(NA)
      pct_rank(x[1:i])[i]
    })
  } else {
    sapply(1:length(x), function(i) {
      start <- max(1, i - n + 1)
      if (sum(!is.na(x[start:i])) < 2) return(NA)
      pct_rank(x[start:i])[i - start + 1]
    })
  }
}

calc_roc <- function(prices, n) {
  if (length(prices) <= n) return(rep(NA, length(prices)))
  c(rep(NA, n), diff(prices, n) / lag(prices, n)[(n+1):length(prices)])
}

# 安全获取最后值的函数
safe_last <- function(x, default = NA) {
  if (length(x) == 0 || all(is.na(x))) return(default)
  val <- tail(na.omit(x), 1)
  if (length(val) == 0) return(default)
  return(val)
}

log_message <- function(msg, level = "INFO") {
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  log_entry <- paste0("[", timestamp, "] [", level, "] ", msg)
  message(log_entry)
  log_file <- file.path(OUTPUT_DIR, "analysis.log")
  cat(log_entry, "\n", file = log_file, append = TRUE)
}

# =============================================================================
# Data Download
# =============================================================================

yahooDownload <- function(tickers, sDate, eDate) {
  log_message(paste("Downloading", nrow(tickers), "tickers"))
  sTime <- Sys.time()
  yahooData <- list()
  
  for (i in 1:nrow(tickers)) {
    tryCatch({
      symbol <- tickers$ticker[i]
      name <- tickers$name[i]
      log_message(paste("Downloading:", name))
      
      data <- getSymbols(symbol, from = sDate, to = eDate, src = "yahoo", auto.assign = FALSE)
      if (!is.null(data) && nrow(data) > 0) {
        df <- xts_to_tbl(data)
        colnames(df) <- c("Open", "High", "Low", "Close", "Volume", "Last", "Date")
        df <- df[, c("Date", "Open", "High", "Low", "Close", "Volume", "Last")]
        yahooData[[name]] <- df
        log_message(paste("✓", name, ":", nrow(df), "rows"))
      }
    }, error = function(e) {
      log_message(paste("✗", tickers$name[i], "failed"), "ERROR")
    })
  }
  
  if (length(yahooData) > 0) {
    write.xlsx(yahooData, file.path(OUTPUT_DIR, "data.xlsx"), overwrite = TRUE)
    log_message(paste("Saved", length(yahooData), "instruments"))
  }
  invisible(yahooData)
}

# =============================================================================
# Data Analysis
# =============================================================================

DataAnalysis <- function(tickers) {
  log_message("Analyzing data...")
  
  data_file <- file.path(OUTPUT_DIR, "data.xlsx")
  if (!file.exists(data_file)) return(NULL)
  
  for (i in 1:nrow(tickers)) {
    name <- tickers$name[i]
    tryCatch({
      data <- read.xlsx(data_file, sheet = name)
      if (is.null(data) || nrow(data) < dataCheck) {
        log_message(paste("Skip:", name, "- insufficient data"), "WARN")
        next
      }
      
      data$Date <- as.Date(data$Date)
      data <- data %>% arrange(Date)
      
      # 移除NA行
      data <- data %>% filter(!is.na(Last), !is.na(High), !is.na(Low))
      
      if (nrow(data) < dataCheck) {
        log_message(paste("Skip:", name, "- insufficient data after NA removal"), "WARN")
        next
      }
      
      # 计算指标
      data$Return <- c(NA, diff(data$Last) / head(data$Last, -1))
      data$MA5 <- EMA(data$Last, n = 5)
      data$MA21 <- EMA(data$Last, n = 21)
      data$MA89 <- EMA(data$Last, n = 89)
      data$MA144 <- EMA(data$Last, n = 144)
      
      data$Dev5 <- data$Last / data$MA5 - 1
      data$Dev21 <- data$Last / data$MA21 - 1
      data$Dev89 <- data$Last / data$MA89 - 1
      data$Dev144 <- data$Last / data$MA144 - 1
      
      data$Range <- data$High - data$Low
      data$ATR <- zoo::rollapply(data$Range, ATRCalWindow, mean, fill = NA, align = "right")
      data$DVol <- zoo::rollapply(data$Return, VolCalWindow, sd, fill = NA, align = "right")
      
      data$Chg5 <- calc_roc(data$Last, 5)
      data$Chg20 <- calc_roc(data$Last, 20)
      data$Chg60 <- calc_roc(data$Last, 60)
      
      write.xlsx(data, file.path(DATA_ANALYSIS_DIR, paste0(name, "_DataAnalysis.xlsx")), overwrite = TRUE)
      log_message(paste("✓ Analyzed:", name))
    }, error = function(e) {
      log_message(paste("Error:", name, conditionMessage(e)), "ERROR")
    })
  }
  log_message("Analysis done!")
}

# =============================================================================
# Data Report
# =============================================================================

DataReport <- function(tickers) {
  log_message("Generating report...")
  results <- list()
  
  for (name in tickers$name) {
    file <- file.path(DATA_ANALYSIS_DIR, paste0(name, "_DataAnalysis.xlsx"))
    if (file.exists(file)) {
      tryCatch({
        data <- read.xlsx(file)
        if (nrow(data) > 0) {
          last <- tail(data, 1)
          results[[name]] <- data.frame(
            Name = name, 
            Last = last$Last, 
            Return = last$Return, 
            DVol = last$DVol,
            Dev89 = last$Dev89,
            stringsAsFactors = FALSE
          )
        }
      }, error = function(e) {})
    }
  }
  
  if (length(results) > 0) {
    report <- do.call(rbind, results)
    write.xlsx(report, file.path(OUTPUT_DIR, paste0(eDate, "_AnalysisReport.xlsx")), overwrite = TRUE)
    log_message(paste("Report:", nrow(report), "instruments"))
  }
}

# =============================================================================
# Data Visualization - 修复版（处理NA和空值）
# =============================================================================

DataVisualization <- function(tickers) {
  log_message("Creating charts...")
  
  for (name in tickers$name) {
    file <- file.path(DATA_ANALYSIS_DIR, paste0(name, "_DataAnalysis.xlsx"))
    if (!file.exists(file)) next
    
    tryCatch({
      Data <- read.xlsx(file)
      Data$Date <- as.Date(Data$Date)
      
      # 移除NA行
      Data <- Data %>% filter(!is.na(Last), !is.na(Date))
      
      if (nrow(Data) < 30) {
        log_message(paste("Skip chart:", name, "- insufficient data"), "WARN")
        next
      }
      
      # 获取安全的最后值
      last_price <- safe_last(Data$Last, 0)
      last_ma5 <- safe_last(Data$MA5, 0)
      last_ma21 <- safe_last(Data$MA21, 0)
      last_ma89 <- safe_last(Data$MA89, 0)
      last_ma144 <- safe_last(Data$MA144, 0)
      
      # Chart 1: Price Development
      Prices <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~Last, name = paste("Last:", round(last_price, 2)),
                  line = list(color = "black", width = 1)) %>%
        add_trace(x = ~Date, y = ~MA5, name = paste("MA5:", round(last_ma5, 2)),
                  line = list(color = "red", width = 1)) %>%
        add_trace(x = ~Date, y = ~MA21, name = paste("MA21:", round(last_ma21, 2)),
                  line = list(color = "blue", width = 1)) %>%
        add_trace(x = ~Date, y = ~MA89, name = paste("MA89:", round(last_ma89, 2)),
                  line = list(color = "green", width = 1)) %>%
        add_trace(x = ~Date, y = ~MA144, name = paste("MA144:", round(last_ma144, 2)),
                  line = list(color = "orange", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "Prices"))
      
      # Chart 2: Deviations
      last_dev89 <- safe_last(Data$Dev89, 0)
      last_dev5 <- safe_last(Data$Dev5, 0)
      last_dev21 <- safe_last(Data$Dev21, 0)
      last_dev144 <- safe_last(Data$Dev144, 0)
      
      Deviations <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~Dev89, name = paste("Dev89:", round(last_dev89 * 100, 2), "%"),
                  line = list(color = "green", width = 2)) %>%
        add_trace(x = ~Date, y = ~Dev5, name = paste("Dev5:", round(last_dev5 * 100, 2), "%"),
                  line = list(color = "red", width = 1)) %>%
        add_trace(x = ~Date, y = ~Dev21, name = paste("Dev21:", round(last_dev21 * 100, 2), "%"),
                  line = list(color = "blue", width = 1)) %>%
        add_trace(x = ~Date, y = ~Dev144, name = paste("Dev144:", round(last_dev144 * 100, 2), "%"),
                  line = list(color = "orange", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "Deviations(%)"))
      
      PriceDevelopment <- subplot(Prices, Deviations, nrows = 2, shareX = TRUE, titleY = TRUE) %>%
        layout(title = list(text = paste(Sys.Date(), "|", name, "|PriceDevelopment"),
                            font = list(size = 15)),
               annotations = source_annotation)
      
      # Chart 3: Volatility
      VolChart <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~DVol, name = "DVol",
                  line = list(color = "blue", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "Volatility"))
      
      # Chart 4: Returns
      RetChart <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~Chg5, name = "Chg5d",
                  line = list(color = "black", width = 1)) %>%
        add_trace(x = ~Date, y = ~Chg20, name = "Chg20d",
                  line = list(color = "red", width = 1)) %>%
        add_trace(x = ~Date, y = ~Chg60, name = "Chg60d",
                  line = list(color = "blue", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "Returns"))
      
      # Combined Charts
      ChartsPac <- htmltools::tagList(
        htmltools::div(PriceDevelopment, style = "margin-bottom:40px;"),
        htmltools::div(VolChart, style = "margin-bottom:40px;"),
        htmltools::div(RetChart, style = "margin-bottom:40px;")
      )
      
      html_file <- file.path(CHARTING_DIR, paste0(Sys.Date(), "_", name, ".html"))
      htmlwidgets::saveWidget(ChartsPac, html_file, selfcontained = TRUE)
      log_message(paste("✓ Charts saved:", name))
      
    }, error = function(e) {
      log_message(paste("Chart error:", name, conditionMessage(e)), "ERROR")
    })
  }
  log_message("Charts done!")
}

# =============================================================================
# Main
# =============================================================================

main <- function() {
  log_message("=== Cloud Market Analytics Started ===")
  
  tickers_file <- file.path(INPUT_DIR, "tickers_macro.xlsx")
  if (!file.exists(tickers_file)) {
    log_message("ERROR: tickers file not found")
    return()
  }
  
  instruments <- read.xlsx(tickers_file)
  log_message(paste("Loaded", nrow(instruments), "instruments"))
  
  log_message("Step 1/4: Downloading...")
  yahooDownload(instruments, sDate, eDate)
  
  log_message("Step 2/4: Analyzing...")
  DataAnalysis(instruments)
  
  log_message("Step 3/4: Reporting...")
  DataReport(instruments)
  
  log_message("Step 4/4: Visualizing...")
  DataVisualization(instruments)
  
  log_message("=== Completed ===")
}

main()
