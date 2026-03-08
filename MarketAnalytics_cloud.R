#!/usr/bin/env Rscript
# Cloud-Ready Market Analytics Script - 完整修复版
# 包含所有7组图表，修复包依赖问题，保持原始参数

# =============================================================================
# Environment Setup
# =============================================================================

WORK_DIR <- Sys.getenv("WORK_DIR", getwd())
INPUT_DIR <- file.path(WORK_DIR, "input")
OUTPUT_DIR <- file.path(WORK_DIR, "output")
DATA_ANALYSIS_DIR <- file.path(OUTPUT_DIR, "dataAnalysis")
CHARTING_DIR <- file.path(OUTPUT_DIR, "charting", "0html_ChartsPac")

for (dir in c(OUTPUT_DIR, DATA_ANALYSIS_DIR, CHARTING_DIR)) {
  if (!dir.exists(dir)) {
    dir.create(dir, recursive = TRUE, showWarnings = FALSE)
  }
}

setwd(WORK_DIR)

# =============================================================================
# Package Management - 修复版（避免ggrepel等包问题）
# =============================================================================

message("Loading packages...")

# 核心包列表（移除有问题的包）
packages <- c(
  "quantmod", "xts", "openxlsx", "dplyr", "tidyr", "lubridate",
  "plotly", "htmltools", "htmlwidgets", "TTR", "zoo", "tibble"
)

# 安装并加载包
for (pkg in packages) {
  if (!require(pkg, character.only = TRUE, quietly = TRUE)) {
    message(paste("Installing package:", pkg))
    install.packages(pkg, repos = "https://cloud.r-project.org/", 
                     dependencies = TRUE, quiet = TRUE)
    library(pkg, character.only = TRUE)
  }
}

# 单独处理tidyquant（使用try避免失败）
tryCatch({
  if (!require("tidyquant", quietly = TRUE)) {
    install.packages("tidyquant", repos = "https://cloud.r-project.org/", quiet = TRUE)
  }
  library(tidyquant)
}, error = function(e) {
  message("tidyquant not available, using fallback functions")
})

message("All packages loaded successfully!")

# =============================================================================
# Parameters Configuration - 保持原始参数不变！
# =============================================================================

dataHistory <- 10
eDate <- Sys.Date()
sDate <- eDate - years(dataHistory)

portfolioVol <- "ATR"
maMode <- "EMA"
maFun <- switch(maMode, "EMA" = TTR::EMA, "SMA" = TTR::SMA)
maParameters <- c(5, 21, 89, 144)

extremeCut <- c(0.01, 1 - 0.01)
warningCut <- c(0.05, 1 - 0.05)

VolCalWindow <- 20
ATRCalWindow <- 6
VaRCalWindow <- 750  # 保持原始750！
RollWindow <- 180
CorWindow <- 60

ChgPeriod <- c(5, 20, 60, 120, 180, 250)
LeadMA <- "MAfast"
LagMA <- "MAslow"

dataCheck <- max(VolCalWindow, ATRCalWindow, VaRCalWindow, 
                 RollWindow, CorWindow, maParameters, ChgPeriod, 250)

head <- "TraderX-Flow-Cloud"
source_annotation <- list(
  x = 0, y = 0.01,
  text = "Cloud Analytics | GitHub Actions",
  showarrow = FALSE,
  xref = 'paper', yref = 'paper',
  xanchor = 'left', yanchor = 'auto',
  xshift = 0, yshift = 0,
  font = list(size = 10, color = "black")
)

# =============================================================================
# Helper Functions - Fallback for tidyquant functions
# =============================================================================

# Fallback xts to tbl conversion
xts_to_tbl <- function(xts_data) {
  df <- as.data.frame(xts_data)
  df$Date <- index(xts_data)
  rownames(df) <- NULL
  return(as_tibble(df))
}

# Fallback tq_mutate using base R
roll_apply_col <- function(data, col_name, width, FUN, new_name) {
  col_idx <- which(names(data) == col_name)
  if (length(col_idx) == 0) return(data)
  
  values <- data[[col_idx]]
  result <- zoo::rollapply(values, width = width, FUN = FUN, 
                          fill = NA, align = "right")
  data[[new_name]] <- result
  return(data)
}

# Fallback ROC calculation
calc_roc <- function(prices, n, type = "discrete") {
  if (length(prices) <= n) return(rep(NA, length(prices)))
  
  if (type == "discrete") {
    result <- c(rep(NA, n), diff(prices, n) / lag(prices, n)[(n+1):length(prices)])
  } else {
    result <- c(rep(NA, n), log(prices[(n+1):length(prices)] / prices[1:(length(prices)-n)]))
  }
  return(result)
}

# Fallback percent_rank
pct_rank <- function(x) {
  if (all(is.na(x))) return(rep(NA, length(x)))
  rank(x, na.last = "keep") / sum(!is.na(x))
}

# Fallback runPercentRank
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

# =============================================================================
# Logging Utility
# =============================================================================

log_message <- function(msg, level = "INFO") {
  timestamp <- format(Sys.time(), "%Y-%m-%d %H:%M:%S")
  log_entry <- paste0("[", timestamp, "] [", level, "] ", msg)
  message(log_entry)
  log_file <- file.path(OUTPUT_DIR, "analysis.log")
  cat(log_entry, "\n", file = log_file, append = TRUE)
}

# =============================================================================
# Data Download Function
# =============================================================================

yahooDownload <- function (tickers, sDate, eDate) {
  log_message(paste("Starting data download for", nrow(tickers), "tickers"))
  sTime <- Sys.time()
  yahooData <- list()
  
  for (i in 1:length(tickers$name)) {
    tryCatch({
      ticker_row <- tickers[i, ]
      ticker_symbol <- ticker_row$ticker
      ticker_name <- ticker_row$name
      
      log_message(paste("Downloading:", ticker_name, "(", ticker_symbol, ")"))
      
      yahooData[[i]] <- na.omit(
        getSymbols(ticker_symbol, from = sDate, to = eDate, 
                   src = "yahoo", auto.assign = FALSE)
      )
      
      # Convert to tibble
      yahooData[[i]] <- xts_to_tbl(yahooData[[i]])
      colnames(yahooData[[i]]) <- c("Open", "High", "Low", "Close", "Volume", "Last", "Date")
      yahooData[[i]] <- yahooData[[i]][, c("Date", "Open", "High", "Low", "Close", "Volume", "Last")]
      
      log_message(paste("Successfully downloaded:", ticker_name))
    },
    error = function(e) {
      log_message(paste("ERROR: Failed to download", tickers$name[i], 
                       "-", conditionMessage(e)), "ERROR")
      yahooData[[i]] <- NA
    })
  }
  
  # Save with names
  names(yahooData) <- tickers$name
  data_file <- file.path(OUTPUT_DIR, "data.xlsx")
  write.xlsx(yahooData, file = data_file, overwrite = TRUE)
  
  eTime <- Sys.time()
  log_message(paste("Data download completed in", round(eTime - sTime, 2), "seconds"))
  
  invisible(yahooData)
}

# =============================================================================
# Data Analysis Function - 完整版
# =============================================================================

DataAnalysis <- function (tickers) {
  log_message("Starting data analysis...")
  
  for (i in 1:length(tickers$name)) {
    tryCatch({
      log_message(paste("Analyzing:", tickers$name[i]))
      
      # Read data
      data_file <- file.path(OUTPUT_DIR, "data.xlsx")
      data <- tryCatch({
        as_tibble(read.xlsx(data_file, sheet = tickers$name[i]))
      }, error = function(e) {
        log_message(paste("No data sheet for:", tickers$name[i]), "WARN")
        NULL
      })
      
      if (is.null(data) || nrow(data) == 0) {
        log_message(paste("Skipping:", tickers$name[i], "- no data"), "WARN")
        next
      }
      
      # Process data
      data$Date <- as.Date(data$Date)
      data <- data %>% 
        select(Date, Last, High, Low) %>%
        drop_na()
      
      if (nrow(data) <= dataCheck) {
        log_message(paste("Skipping:", tickers$name[i], "- insufficient data"), "WARN")
        next
      }
      
      # Data calculation - using fallback functions
      data <- data %>%
        mutate(
          LastHistRank = pct_rank(Last),
          LastRollRank = run_pct_rank(Last, n = RollWindow, cumulative = FALSE),
          Range = High - Low,
          RangePerc = Range / lag(Last),
          Return = Last / lag(Last) - 1
        ) %>%
        mutate(
          HistMax = cummax(High),
          HistMin = cummin(Low),
          ToHistMax = (HistMax - Last) / Last,
          ToHistMin = (HistMin - Last) / Last,
          HistDrawDown = (Last - HistMax) / HistMax,
          HistDrawDownHistRank = pct_rank(HistDrawDown),
          HistDrawDownRollRank = run_pct_rank(HistDrawDown, n = RollWindow, cumulative = FALSE),
          HistDrawUp = (Last - HistMin) / HistMin,
          HistDrawUpHistRank = pct_rank(HistDrawUp),
          HistDrawUpRollRank = run_pct_rank(HistDrawUp, n = RollWindow, cumulative = FALSE)
        )
      
      # ATR calculations
      data$ATR <- zoo::rollapply(data$Range, width = ATRCalWindow, FUN = mean, 
                                fill = NA, align = "right")
      data$ATRPerc <- data$ATR / lag(data$Last)
      
      # DVol
      data$DVol <- zoo::rollapply(data$Return, width = VolCalWindow, FUN = sd, 
                                fill = NA, align = "right")
      
      # VaR - 保持原始750窗口
      data$LongVaRPerc <- zoo::rollapply(data$Return, width = VaRCalWindow, 
        FUN = function(x) quantile(x, extremeCut[1], na.rm = TRUE),
        fill = NA, align = "right")
      data$ShortVaRPerc <- zoo::rollapply(data$Return, width = VaRCalWindow,
        FUN = function(x) quantile(x, extremeCut[2], na.rm = TRUE),
        fill = NA, align = "right")
      
      # RollMax/Min
      data$RollMax <- zoo::rollapply(data$High, width = RollWindow, FUN = max, fill = NA, align = "right")
      data$RollMin <- zoo::rollapply(data$Low, width = RollWindow, FUN = min, fill = NA, align = "right")
      
      data <- data %>%
        mutate(
          RollDrawDown = Last / RollMax - 1,
          RollDrawUp = Last / RollMin - 1,
          RollDrawDownHistRank = pct_rank(RollDrawDown),
          RollDrawDownRollRank = run_pct_rank(RollDrawDown, n = RollWindow, cumulative = FALSE),
          RollDrawUpHistRank = pct_rank(RollDrawUp),
          RollDrawUpRollRank = run_pct_rank(RollDrawUp, n = RollWindow, cumulative = FALSE)
        ) %>%
        mutate(
          RangePercHistRank = pct_rank(RangePerc),
          RangePercRollRank = run_pct_rank(RangePerc, n = RollWindow, cumulative = FALSE),
          ATRPercHistRank = pct_rank(ATRPerc),
          ATRPercRollRank = run_pct_rank(ATRPerc, n = RollWindow, cumulative = FALSE),
          DVolHistRank = pct_rank(DVol),
          DVolRollRank = run_pct_rank(DVol, n = RollWindow, cumulative = FALSE)
        )
      
      # MA calculations
      data$MAfast <- maFun(data$Last, n = maParameters[1])
      data$MAslow <- maFun(data$Last, n = maParameters[2])
      data$MAkey <- maFun(data$Last, n = maParameters[3])
      data$MAlongterm <- maFun(data$Last, n = maParameters[4])
      
      data <- data %>%
        mutate(
          DevFast = Last / MAfast - 1,
          DevSlow = Last / MAslow - 1,
          DevKey = Last / MAkey - 1,
          DevLongterm = Last / MAlongterm - 1,
          DevMA_FastSlow = MAfast / MAslow - 1,
          DevKeyHistRank = pct_rank(DevKey),
          DevKeyRollRank = run_pct_rank(DevKey, n = RollWindow, cumulative = FALSE)
        )
      
      # Changes using fallback ROC
      for (j in 1:length(ChgPeriod)) {
        col_name <- paste0("Chg", LETTERS[j])
        data[[col_name]] <- calc_roc(data$Last, n = ChgPeriod[j], type = "discrete")
      }
      
      # Sigma calculations
      for (j in 1:length(ChgPeriod)) {
        chg_col <- paste0("Chg", LETTERS[j])
        sigma_col <- paste0("Sigma", LETTERS[j])
        data[[sigma_col]] <- data[[chg_col]] / (data$DVol * sqrt(ChgPeriod[j]))
      }
      
      # Rename columns
      new_names <- c(
        paste0(maMode, maParameters[1]),
        paste0(maMode, maParameters[2]),
        paste0(maMode, maParameters[3]),
        paste0(maMode, maParameters[4]),
        paste0(maMode, "Dev", maParameters[1]),
        paste0(maMode, "Dev", maParameters[2]),
        paste0(maMode, "Dev", maParameters[3]),
        paste0(maMode, "Dev", maParameters[4]),
        paste0(maMode, "_MADev_", maParameters[1], "_", maParameters[2]),
        paste0(maMode, "Dev", maParameters[3], "HistRank"),
        paste0(maMode, "Dev", maParameters[3], "RollRank"),
        paste0("Chg", ChgPeriod[1], "DPerc"),
        paste0("Chg", ChgPeriod[2], "DPerc"),
        paste0("Chg", ChgPeriod[3], "DPerc"),
        paste0("Chg", ChgPeriod[4], "DPerc"),
        paste0("Chg", ChgPeriod[5], "DPerc"),
        paste0("Chg", ChgPeriod[6], "DPerc"),
        paste0("Sigma", ChgPeriod[1], "D"),
        paste0("Sigma", ChgPeriod[2], "D"),
        paste0("Sigma", ChgPeriod[3], "D"),
        paste0("Sigma", ChgPeriod[4], "D"),
        paste0("Sigma", ChgPeriod[5], "D"),
        paste0("Sigma", ChgPeriod[6], "D")
      )
      
      col_indices <- c(21:24, 25:31, 50:61)
      existing_cols <- names(data)
      for (idx in 1:length(col_indices)) {
        if (col_indices[idx] <= length(existing_cols)) {
          names(data)[col_indices[idx]] <- new_names[idx]
        }
      }
      
      # Save
      write.xlsx(data,
                 file = file.path(DATA_ANALYSIS_DIR, paste0(tickers$name[i], "_DataAnalysis.xlsx")),
                 overwrite = TRUE)
      
      log_message(paste("Analysis saved:", tickers$name[i]))
    },
    error = function(e) {
      log_message(paste("ERROR analyzing", tickers$name[i], ":", conditionMessage(e)), "ERROR")
    })
  }
  
  log_message("Data analysis completed!")
}

# =============================================================================
# Data Report Function
# =============================================================================

DataReport <- function(tickers) {
  log_message("Generating report...")
  
  first_file <- file.path(DATA_ANALYSIS_DIR, paste0(tickers$name[1], "_DataAnalysis.xlsx"))
  if (!file.exists(first_file)) {
    log_message("No analysis files found!", "ERROR")
    return(NULL)
  }
  
  getColums <- colnames(read.xlsx(first_file))
  Fields <- getColums[-1]
  AnalysisLatest <- as.data.frame(matrix(nrow = 0, ncol = length(Fields) + 1))
  colnames(AnalysisLatest) <- c("Name", Fields)
  
  for (i in 1:length(tickers$name)) {
    analysis_file <- file.path(DATA_ANALYSIS_DIR, paste0(tickers$name[i], "_DataAnalysis.xlsx"))
    
    if (!file.exists(analysis_file)) {
      log_message(paste("File not found, skipping:", tickers$name[i]), "WARN")
      next
    }
    
    tryCatch({
      temp <- read.xlsx(analysis_file)
      temp <- temp[nrow(temp), Fields]
      AnalysisLatest[i, ] <- c(tickers$name[i], temp)
      log_message(paste("Added to report:", tickers$name[i]))
    }, error = function(e) {
      log_message(paste("Error processing:", tickers$name[i]), "ERROR")
    })
  }
  
  for (i in 2:ncol(AnalysisLatest)) {
    AnalysisLatest[, i] <- as.double(AnalysisLatest[, i])
  }
  
  AnalysisLatest <- drop_na(as_tibble(AnalysisLatest))
  
  write.xlsx(AnalysisLatest, file = file.path(OUTPUT_DIR, paste0(eDate, "_AnalysisReport_plain.xlsx")), overwrite = TRUE)
  write.csv(AnalysisLatest, file = file.path(OUTPUT_DIR, paste0(eDate, "_AnalysisReport_plain.csv")), row.names = FALSE)
  
  # Template
  template_file <- file.path(INPUT_DIR, "template_AnalysisReport.xlsx")
  if (file.exists(template_file)) {
    template <- loadWorkbook(template_file)
    writeData(template, sheet = 1, x = AnalysisLatest, startRow = 4, startCol = 1, colNames = FALSE, withFilter = FALSE)
    saveWorkbook(template, file = file.path(OUTPUT_DIR, "AnalysisReport_formal.xlsx"), overwrite = TRUE)
    log_message("Formal report saved")
  }
  
  log_message("Report generation completed!")
}

# =============================================================================
# Data Visualization Function - 完整7组图表版
# =============================================================================

DataVisualization <- function(tickers) {
  log_message("Starting data visualization...")
  
  for (i in 1:length(tickers$name)) {
    inputTicker <- tickers$name[i]
    log_message(paste("Creating charts for:", inputTicker))
    
    analysis_file <- file.path(DATA_ANALYSIS_DIR, paste0(inputTicker, "_DataAnalysis.xlsx"))
    if (!file.exists(analysis_file)) {
      log_message(paste("Analysis file not found, skipping:", inputTicker), "WARN")
      next
    }
    
    tryCatch({
      Data <- as_tibble(read.xlsx(analysis_file))
      Data$Date <- as.Date(Data$Date)
      Data <- Data %>% filter(!is.na(Last))
      
      if (nrow(Data) < 50) {
        log_message(paste("Insufficient data for charts:", inputTicker), "WARN")
        next
      }
      
      # Chart 1: Price Development
      Prices <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~Last, name = paste("Last:", round(tail(Data$Last, 1), 2)),
                  line = list(color = "black", width = 1)) %>%
        add_trace(x = ~Date, y = ~MAfast, name = paste("MA5:", round(tail(Data$MAfast, 1), 2)),
                  line = list(color = "red", width = 1)) %>%
        add_trace(x = ~Date, y = ~MAslow, name = paste("MA21:", round(tail(Data$MAslow, 1), 2)),
                  line = list(color = "blue", width = 1)) %>%
        add_trace(x = ~Date, y = ~MAkey, name = paste("MA89:", round(tail(Data$MAkey, 1), 2)),
                  line = list(color = "green", width = 1)) %>%
        add_trace(x = ~Date, y = ~MAlongterm, name = paste("MA144:", round(tail(Data$MAlongterm, 1), 2)),
                  line = list(color = "orange", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "Prices"))
      
      Deviations <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~DevKey, name = paste("DevKey:", round(tail(Data$DevKey, 1) * 100, 2), "%"),
                  line = list(color = "black", width = 1.5)) %>%
        add_trace(x = ~Date, y = ~DevFast, name = paste("Dev5:", round(tail(Data$DevFast, 1) * 100, 2), "%"),
                  line = list(color = "red", width = 1)) %>%
        add_trace(x = ~Date, y = ~DevSlow, name = paste("Dev21:", round(tail(Data$DevSlow, 1) * 100, 2), "%"),
                  line = list(color = "blue", width = 1)) %>%
        add_trace(x = ~Date, y = ~DevLongterm, name = paste("Dev144:", round(tail(Data$DevLongterm, 1) * 100, 2), "%"),
                  line = list(color = "green", width = 1.5)) %>%
        add_trace(x = ~Date, y = ~DevMA_FastSlow, name = paste("DevMA:", round(tail(Data$DevMA_FastSlow, 1) * 100, 2), "%"),
                  line = list(color = "orange", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = paste(maMode, " Deviations(%)")))
      
      PriceDevelopment <- subplot(Prices, Deviations, nrows = 2, shareX = TRUE, titleY = TRUE) %>%
        layout(title = list(text = paste(Sys.Date(), "|", inputTicker, "|PriceDevelopment@", head, sep = ""),
                            font = list(size = 15)),
               legend = list(title = list(text = "Indicators"), bgcolor = 'transparent', size = 9),
               annotations = source_annotation)
      
      # Chart 2: Risk Management
      Volatilities <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~RangePerc, name = paste("Range%:", round(tail(Data$RangePerc, 1) * 100, 2), "%"),
                  line = list(color = "black", width = 1)) %>%
        add_trace(x = ~Date, y = ~ATRPerc, name = paste("ATR%:", round(tail(Data$ATRPerc, 1) * 100, 2), "%"),
                  line = list(color = "red", width = 1)) %>%
        add_trace(x = ~Date, y = ~DVol, name = paste("DVol:", round(tail(Data$DVol, 1) * 100, 2), "%"),
                  line = list(color = "blue", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "Volatilities(%)"))
      
      ValueRisk <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~LongVaRPerc, name = paste("LongVaR:", round(tail(Data$LongVaRPerc, 1) * 100, 2), "%"),
                  line = list(color = "red", width = 1)) %>%
        add_trace(x = ~Date, y = ~ShortVaRPerc, name = paste("ShortVaR:", round(tail(Data$ShortVaRPerc, 1) * 100, 2), "%"),
                  line = list(color = "green", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "VaR(%)"))
      
      RiskManagement <- subplot(Prices, Volatilities, ValueRisk, nrows = 3, shareX = TRUE, titleY = TRUE) %>%
        layout(title = list(text = paste(Sys.Date(), "|", inputTicker, "|RiskManagement@", head, sep = ""),
                            font = list(size = 15)),
               legend = list(title = list(text = "Indicators"), bgcolor = 'transparent', size = 9),
               annotations = source_annotation)
      
      # Chart 3: VolView ATR
      ATRView <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~ATRPerc, name = paste("ATR%:", round(tail(Data$ATRPerc, 1) * 100, 2), "%"),
                  line = list(color = "black", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "ATR(%)"))
      
      ATRRank <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~ATRPercHistRank, name = paste("HistRank:", round(tail(Data$ATRPercHistRank, 1), 2)),
                  line = list(color = "red", width = 1)) %>%
        add_trace(x = ~Date, y = ~ATRPercRollRank, name = paste("RollRank:", round(tail(Data$ATRPercRollRank, 1), 2)),
                  line = list(color = "blue", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "ATR(%) Rank"))
      
      VolViewATR <- subplot(Prices, ATRView, ATRRank, nrows = 3, shareX = TRUE, titleY = TRUE) %>%
        layout(title = list(text = paste(Sys.Date(), "|", inputTicker, "|VolView_ATR(%)@", head, sep = ""),
                            font = list(size = 15)),
               legend = list(title = list(text = "Indicators"), bgcolor = 'transparent', size = 9),
               annotations = source_annotation)
      
      # Chart 4: VolView DVol
      DVolView <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~DVol, name = paste("DVol:", round(tail(Data$DVol, 1) * 100, 2), "%"),
                  line = list(color = "black", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "DVol"))
      
      DVolRank <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~DVolHistRank, name = paste("HistRank:", round(tail(Data$DVolHistRank, 1), 2)),
                  line = list(color = "red", width = 1)) %>%
        add_trace(x = ~Date, y = ~DVolRollRank, name = paste("RollRank:", round(tail(Data$DVolRollRank, 1), 2)),
                  line = list(color = "blue", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "DVolRank"))
      
      VolViewDVol <- subplot(Prices, DVolView, DVolRank, nrows = 3, shareX = TRUE, titleY = TRUE) %>%
        layout(title = list(text = paste(Sys.Date(), "|", inputTicker, "|VolView_DVol@", head, sep = ""),
                            font = list(size = 15)),
               legend = list(title = list(text = "Indicators"), bgcolor = 'transparent', size = 9),
               annotations = source_annotation)
      
      # Chart 5: VolRank
      VolHistRanks <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~RangePercHistRank, name = paste("Range%:", round(tail(Data$RangePercHistRank, 1), 2)),
                  line = list(color = "black", width = 1)) %>%
        add_trace(x = ~Date, y = ~ATRPercHistRank, name = paste("ATR%:", round(tail(Data$ATRPercHistRank, 1), 2)),
                  line = list(color = "red", width = 1)) %>%
        add_trace(x = ~Date, y = ~DVolHistRank, name = paste("DVol:", round(tail(Data$DVolHistRank, 1), 2)),
                  line = list(color = "blue", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "VolHistoricalRank"))
      
      VolRollRanks <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~RangePercRollRank, name = paste("Range%:", round(tail(Data$RangePercRollRank, 1), 2)),
                  line = list(color = "black", width = 1)) %>%
        add_trace(x = ~Date, y = ~ATRPercRollRank, name = paste("ATR%:", round(tail(Data$ATRPercRollRank, 1), 2)),
                  line = list(color = "red", width = 1)) %>%
        add_trace(x = ~Date, y = ~DVolRollRank, name = paste("DVol:", round(tail(Data$DVolRollRank, 1), 2)),
                  line = list(color = "blue", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = paste("VolRankRollWindow@", RollWindow)))
      
      VolRank <- subplot(Volatilities, VolHistRanks, VolRollRanks, nrows = 3, shareX = TRUE, titleY = TRUE) %>%
        layout(title = list(text = paste(Sys.Date(), "|", inputTicker, "|VolRank@", head, sep = ""),
                            font = list(size = 15)),
               legend = list(title = list(text = "Indicators"), bgcolor = 'transparent', size = 9),
               annotations = source_annotation)
      
      # Chart 6: Periodic Performances
      ChgA_col <- paste0("Chg", ChgPeriod[1], "DPerc")
      ChgB_col <- paste0("Chg", ChgPeriod[2], "DPerc")
      ChgC_col <- paste0("Chg", ChgPeriod[3], "DPerc")
      ChgD_col <- paste0("Chg", ChgPeriod[4], "DPerc")
      ChgE_col <- paste0("Chg", ChgPeriod[5], "DPerc")
      ChgF_col <- paste0("Chg", ChgPeriod[6], "DPerc")
      
      ChgPercView <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = as.formula(paste0("~", ChgA_col)), name = paste("Chg5:", round(tail(Data[[ChgA_col]], 1) * 100, 2), "%"),
                  line = list(color = "black", width = 1)) %>%
        add_trace(x = ~Date, y = as.formula(paste0("~", ChgB_col)), name = paste("Chg20:", round(tail(Data[[ChgB_col]], 1) * 100, 2), "%"),
                  line = list(color = "red", width = 1)) %>%
        add_trace(x = ~Date, y = as.formula(paste0("~", ChgC_col)), name = paste("Chg60:", round(tail(Data[[ChgC_col]], 1) * 100, 2), "%"),
                  line = list(color = "blue", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "Chg(%)"))
      
      SigmaA_col <- paste0("Sigma", ChgPeriod[1], "D")
      SigmaB_col <- paste0("Sigma", ChgPeriod[2], "D")
      SigmaC_col <- paste0("Sigma", ChgPeriod[3], "D")
      
      SigmaView <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = as.formula(paste0("~", SigmaA_col)), name = paste("Sigma5:", round(tail(Data[[SigmaA_col]], 1), 2)),
                  line = list(color = "black", width = 1)) %>%
        add_trace(x = ~Date, y = as.formula(paste0("~", SigmaB_col)), name = paste("Sigma20:", round(tail(Data[[SigmaB_col]], 1), 2)),
                  line = list(color = "red", width = 1)) %>%
        add_trace(x = ~Date, y = as.formula(paste0("~", SigmaC_col)), name = paste("Sigma60:", round(tail(Data[[SigmaC_col]], 1), 2)),
                  line = list(color = "blue", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "Sigma"))
      
      PeriodicPerf <- subplot(Prices, ChgPercView, SigmaView, nrows = 3, shareX = TRUE, titleY = TRUE) %>%
        layout(title = list(text = paste(Sys.Date(), "|", inputTicker, "|PeriodicPerformances@", head, sep = ""),
                            font = list(size = 15)),
               legend = list(title = list(text = "Indicators"), bgcolor = 'transparent', size = 9),
               annotations = source_annotation)
      
      # Chart 7: DrawDowns Ups
      DrawDown <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~HistDrawDown, name = paste("HistDD:", round(tail(Data$HistDrawDown, 1) * 100, 2), "%"),
                  line = list(color = "black", width = 1)) %>%
        add_trace(x = ~Date, y = ~RollDrawDown, name = paste("RollDD:", round(tail(Data$RollDrawDown, 1) * 100, 2), "%"),
                  line = list(color = "red", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "DrawDowns"))
      
      DrawUp <- plot_ly(Data, type = 'scatter', mode = 'lines') %>%
        add_trace(x = ~Date, y = ~HistDrawUp, name = paste("HistUp:", round(tail(Data$HistDrawUp, 1) * 100, 2), "%"),
                  line = list(color = "black", width = 1)) %>%
        add_trace(x = ~Date, y = ~RollDrawUp, name = paste("RollUp:", round(tail(Data$RollDrawUp, 1) * 100, 2), "%"),
                  line = list(color = "red", width = 1)) %>%
        layout(xaxis = list(title = ""), yaxis = list(title = "DrawUps"))
      
      DrawDownsUps <- subplot(Prices, DrawDown, DrawUp, nrows = 3, shareX = TRUE, titleY = TRUE) %>%
        layout(title = list(text = paste(Sys.Date(), "|", inputTicker, "|DrawDownsUps@", head, sep = ""),
                            font = list(size = 15)),
               legend = list(title = list(text = "Indicators"), bgcolor = 'transparent', size = 9),
               annotations = source_annotation)
      
      # Combined Charts Output - 所有7组图表合并保存
      ChartsPac <- htmltools::tagList(
        htmltools::div(PriceDevelopment, style = "margin-bottom:40px;"),
        htmltools::div(RiskManagement, style = "margin-bottom:40px;"),
        htmltools::div(VolViewATR, style = "margin-bottom:40px;"),
        htmltools::div(VolViewDVol, style = "margin-bottom:40px;"),
        htmltools::div(VolRank, style = "margin-bottom:40px;"),
        htmltools::div(PeriodicPerf, style = "margin-bottom:40px;"),
        htmltools::div(DrawDownsUps, style = "margin-bottom:40px;")
      )
      
      html_file <- file.path(CHARTING_DIR, paste0(Sys.Date(), "_", inputTicker, ".html"))
      htmlwidgets::saveWidget(ChartsPac, file = html_file, selfcontained = TRUE)
      
      log_message(paste("All 7 charts saved for:", inputTicker))
      
    }, error = function(e) {
      log_message(paste("Error creating charts for", inputTicker, ":", conditionMessage(e)), "ERROR")
    })
  }
  
  log_message("Visualization completed!")
}

# =============================================================================
# Main Execution
# =============================================================================

main <- function() {
  log_message("============================================")
  log_message("Cloud Market Analytics Pipeline Started")
  log_message(paste("Date:", eDate))
  log_message("============================================")
  
  tickers_file <- file.path(INPUT_DIR, "tickers_macro.xlsx")
  if (!file.exists(tickers_file)) {
    log_message("Tickers file not found!", "ERROR")
    stop("Input file not found!")
  }
  
  instruments <- read.xlsx(tickers_file)
  log_message(paste("Loaded", nrow(instruments), "instruments"))
  
  log_message("Step 1/4: Downloading data...")
  yahooDownload(instruments, sDate, eDate)
  
  log_message("Step 2/4: Analyzing data...")
  DataAnalysis(instruments)
  
  log_message("Step 3/4: Generating report...")
  DataReport(instruments)
  
  log_message("Step 4/4: Creating visualizations...")
  DataVisualization(instruments)
  
  log_message("============================================")
  log_message("Pipeline Completed Successfully!")
  log_message("============================================")
}

main()
