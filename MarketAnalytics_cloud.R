#!/usr/bin/env Rscript
# Cloud-Ready Market Analytics - 下载修复版
# 增加重试机制和详细日志

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
# Logging
# =============================================================================

log_message <- function(msg, level = "INFO") {
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  log_entry <- paste0("[", timestamp, "] [", level, "] ", msg)
  message(log_entry)
  log_file <- file.path(OUTPUT_DIR, "analysis.log")
  cat(log_entry, "\n", file = log_file, append = TRUE)
}

log_message("=" %>% rep(60, paste = ""))
log_message("Starting Cloud Market Analytics")
log_message("=" %>% rep(60, paste = ""))

# =============================================================================
# Package Management
# =============================================================================

log_message("Loading packages...")

packages <- c("quantmod", "xts", "openxlsx", "dplyr", "plotly", "htmltools", "htmlwidgets", "TTR", "lubridate", "zoo")

for (pkg in packages) {
  if (!require(pkg, character.only = TRUE, quietly = TRUE)) {
    log_message(paste("Installing package:", pkg))
    install.packages(pkg, repos = "https://cloud.r-project.org/", quiet = TRUE)
    library(pkg, character.only = TRUE)
  }
}

log_message("All packages loaded successfully")

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

safe_last <- function(x, default = NA) {
  if (length(x) == 0 || all(is.na(x))) return(default)
  val <- tail(na.omit(x), 1)
  if (length(val) == 0) return(default)
  return(val)
}

# =============================================================================
# Data Download - 带重试机制
# =============================================================================

yahooDownload <- function(tickers, sDate, eDate) {
  log_message(paste("Starting download for", nrow(tickers), "tickers"))
  sTime <- Sys.time()
  yahooData <- list()
  
  for (i in 1:nrow(tickers)) {
    symbol <- tickers$ticker[i]
    name <- tickers$name[i]
    
    log_message(paste("[", i, "/", nrow(tickers), "] Downloading:", name, "(", symbol, ")"))
    
    # 重试机制
    success <- FALSE
    for (attempt in 1:3) {
      if (attempt > 1) {
        log_message(paste("Retry attempt", attempt, "for", name))
        Sys.sleep(2)  # 等待2秒再试
      }
      
      tryCatch({
        log_message(paste("Attempt", attempt, "- Calling getSymbols..."))
        
        data <- getSymbols(symbol, from = sDate, to = eDate, 
                          src = "yahoo", auto.assign = FALSE)
        
        if (!is.null(data) && nrow(data) > 0) {
          log_message(paste("Got data for", name, "- rows:", nrow(data)))
          
          # 转换格式
          df <- xts_to_tbl(data)
          colnames(df) <- c("Open", "High", "Low", "Close", "Volume", "Last", "Date")
          df <- df[, c("Date", "Open", "High", "Low", "Close", "Volume", "Last")]
          yahooData[[name]] <- df
          
          log_message(paste("✓ SUCCESS:", name, "-", nrow(df), "rows"))
          success <- TRUE
          break  # 成功后跳出重试循环
        } else {
          log_message(paste("✗ Empty data for", name), "WARN")
        }
      }, error = function(e) {
        error_msg <- conditionMessage(e)
        log_message(paste("✗ Attempt", attempt, "failed for", name, ":", error_msg), "ERROR")
        
        # 特殊错误处理
        if (grepl("symbol", error_msg, ignore.case = TRUE)) {
          log_message(paste("  -> Symbol error:", symbol, "may not exist on Yahoo"), "ERROR")
        }
        if (grepl("timeout", error_msg, ignore.case = TRUE)) {
          log_message(paste("  -> Timeout, will retry..."), "WARN")
        }
      })
    }
    
    if (!success) {
      log_message(paste("✗✗✗ FAILED after 3 attempts:", name), "ERROR")
    }
  }
  
  eTime <- Sys.time()
  log_message(paste("Download completed in", round(eTime - sTime, 2), "seconds"))
  log_message(paste("Successfully downloaded:", length(yahooData), "/", nrow(tickers), "instruments"))
  
  # 保存数据
  if (length(yahooData) > 0) {
    data_file <- file.path(OUTPUT_DIR, "data.xlsx")
    write.xlsx(yahooData, data_file, overwrite = TRUE)
    log_message(paste("Data saved to:", data_file))
    
    # 记录成功的股票列表
    success_file <- file.path(OUTPUT_DIR, "download_success.txt")
    writeLines(names(yahooData), success_file)
    log_message(paste("Success list saved to:", success_file))
  } else {
    log_message("WARNING: No data downloaded!", "WARN")
  }
  
  invisible(yahooData)
}

# =============================================================================
# Data Analysis
# =============================================================================

DataAnalysis <- function(tickers) {
  log_message("Starting data analysis...")
  
  data_file <- file.path(OUTPUT_DIR, "data.xlsx")
  if (!file.exists(data_file)) {
    log_message("ERROR: data.xlsx not found!", "ERROR")
    return(NULL)
  }
  
  # 只分析成功下载的数据
  success_list <- file.path(OUTPUT_DIR, "download_success.txt")
  if (file.exists(success_list)) {
    success_names <- readLines(success_list)
    log_message(paste("Analyzing", length(success_names), "successful downloads"))
  } else {
    success_names <- tickers$name
  }
  
  for (name in success_names) {
    log_message(paste("Analyzing:", name))
    
    tryCatch({
      data <- read.xlsx(data_file, sheet = name)
      
      if (is.null(data) || nrow(data) < dataCheck) {
        log_message(paste("Skip:", name, "- insufficient data (", nrow(data), "rows)"), "WARN")
        next
      }
      
      # 处理数据
      data$Date <- as.Date(data$Date)
      data <- data %>% arrange(Date)
      data <- data %>% filter(!is.na(Last), !is.na(High), !is.na(Low))
      
      if (nrow(data) < dataCheck) {
        log_message(paste("Skip:", name, "- after NA removal:", nrow(data), "rows"), "WARN")
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
      log_message(paste("Error analyzing", name, ":", conditionMessage(e)), "ERROR")
    })
  }
  
  log_message("Analysis completed!")
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
    log_message(paste("Report generated with", nrow(report), "instruments"))
  } else {
    log_message("No data for report", "WARN")
  }
}

# =============================================================================
# Data Visualization
# =============================================================================

DataVisualization <- function(tickers) {
  log_message("Creating charts...")
  
  for (name in tickers$name) {
    file <- file.path(DATA_ANALYSIS_DIR, paste0(name, "_DataAnalysis.xlsx"))
    if (!file.exists(file)) next
    
    tryCatch({
      Data <- read.xlsx(file)
      Data$Date <- as.Date(Data$Date)
      Data <- Data %>% filter(!is.na(Last), !is.na(Date))
      
      if (nrow(Data) < 30) {
        log_message(paste("Skip chart:", name, "- insufficient data"), "WARN")
        next
      }
      
      # Get safe last values
      last_price <- safe_last(Data$Last, 0)
      last_ma5 <- safe_last(Data$MA5, 0)
      last_ma21 <- safe_last(Data$MA21, 0)
      last_ma89 <- safe_last(Data$MA89, 0)
      last_ma144 <- safe_last(Data$MA144, 0)
      
      # Simplified charts
      p1 <- plot_ly(Data, x = ~Date, y = ~Last, type = 'scatter', mode = 'lines',
                  name = paste("Price:", round(last_price, 2)),
                  line = list(color = 'black')) %>%
        layout(title = paste(name, "Analysis"), xaxis = list(title = ""), yaxis = list(title = "Price"))
      
      html_file <- file.path(CHARTING_DIR, paste0(Sys.Date(), "_", name, ".html"))
      htmlwidgets::saveWidget(p1, html_file, selfcontained = TRUE)
      log_message(paste("✓ Chart saved:", name))
      
    }, error = function(e) {
      log_message(paste("Chart error:", name, conditionMessage(e)), "ERROR")
    })
  }
  
  log_message("Charts completed!")
}

# =============================================================================
# Main
# =============================================================================

main <- function() {
  log_message("=" %>% rep(60, paste = ""))
  log_message("Cloud Market Analytics Pipeline")
  log_message(paste("Date:", eDate))
  log_message("=" %>% rep(60, paste = ""))
  
  tickers_file <- file.path(INPUT_DIR, "tickers_macro.xlsx")
  if (!file.exists(tickers_file)) {
    log_message("FATAL ERROR: tickers_macro.xlsx not found!", "ERROR")
    return()
  }
  
  instruments <- read.xlsx(tickers_file)
  log_message(paste("Loaded", nrow(instruments), "instruments from tickers file"))
  log_message(paste("Tickers:", paste(instruments$name, collapse = ", ")))
  
  log_message("\nStep 1/4: Downloading data...")
  yahooDownload(instruments, sDate, eDate)
  
  log_message("\nStep 2/4: Analyzing data...")
  DataAnalysis(instruments)
  
  log_message("\nStep 3/4: Generating report...")
  DataReport(instruments)
  
  log_message("\nStep 4/4: Creating visualizations...")
  DataVisualization(instruments)
  
  log_message("\n" %>% rep(60, paste = ""))
  log_message("Pipeline Completed!")
  log_message("=" %>% rep(60, paste = ""))
}

main()
