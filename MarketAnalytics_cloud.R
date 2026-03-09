#!/usr/bin/env Rscript
# Cloud-Ready Market Analytics - 完整修复版 v2
# 修复：slider错误 + 静态图表(PNG/PDF)替代HTML + 优化包安装

# =============================================================================
# Environment Setup
# =============================================================================

WORK_DIR <- Sys.getenv("WORK_DIR", getwd())
INPUT_DIR <- file.path(WORK_DIR, "input")
OUTPUT_DIR <- file.path(WORK_DIR, "output")
DATA_ANALYSIS_DIR <- file.path(OUTPUT_DIR, "dataAnalysis")
CHARTING_DIR <- file.path(OUTPUT_DIR, "charting")

for (dir in c(OUTPUT_DIR, DATA_ANALYSIS_DIR, CHARTING_DIR)) {
  if (!dir.exists(dir)) dir.create(dir, recursive = TRUE, showWarnings = FALSE)
}
setwd(WORK_DIR)

# =============================================================================
# Package Management - 优化版
# =============================================================================

message("Loading packages...")

packages <- c("quantmod", "xts", "openxlsx", "dplyr", "lubridate", "zoo", 
              "TTR", "ggplot2", "gridExtra", "scales")

missing_packages <- c()
for (pkg in packages) {
  if (!require(pkg, character.only = TRUE, quietly = TRUE)) {
    missing_packages <- c(missing_packages, pkg)
  }
}

if (length(missing_packages) > 0) {
  message(paste("Installing missing packages:", paste(missing_packages, collapse = ", ")))
  install.packages(missing_packages, repos = "https://cloud.r-project.org/", quiet = TRUE, Ncpus = 2)
  for (pkg in missing_packages) {
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

maMode <- "EMA"
maFun <- switch(maMode, "EMA" = TTR::EMA, "SMA" = TTR::SMA)
maParameters <- c(5, 21, 89, 144)

extremeCut <- c(0.01, 1 - 0.01)
VolCalWindow <- 20
ATRCalWindow <- 6
VaRCalWindow <- 750
RollWindow <- 180
ChgPeriod <- c(5, 20, 60, 120, 180, 250)

dataCheck <- max(VolCalWindow, ATRCalWindow, VaRCalWindow, RollWindow, 
                 maParameters, ChgPeriod, 250)

# =============================================================================
# Helper Functions
# =============================================================================

xts_to_tbl <- function(xts_data) {
  df <- as.data.frame(xts_data)
  df$Date <- index(xts_data)
  rownames(df) <- NULL
  return(tibble::as_tibble(df))
}

# =============================================================================
# Data Download
# =============================================================================

yahooDownload <- function(tickers, sDate, eDate) {
  message("Downloading data from Yahoo Finance...")
  sTime <- Sys.time()
  yahooData <- list()
  
  for (i in 1:nrow(tickers)) {
    symbol <- tickers$ticker[i]
    name <- tickers$name[i]
    
    message(paste("[", i, "/", nrow(tickers), "]", name, "(", symbol, ")"))
    
    success <- FALSE
    for (attempt in 1:3) {
      if (attempt > 1) {
        message(paste("  Retry attempt", attempt))
        Sys.sleep(2)
      }
      
      tryCatch({
        data <- getSymbols(symbol, from = sDate, to = eDate, 
                          src = "yahoo", auto.assign = FALSE)
        
        if (!is.null(data) && nrow(data) > 0) {
          df <- xts_to_tbl(data)
          colnames(df) <- c("Open", "High", "Low", "Close", "Volume", "Last", "Date")
          df <- df[, c("Date", "Open", "High", "Low", "Close", "Volume", "Last")]
          yahooData[[name]] <- df
          message(paste("  SUCCESS:", nrow(df), "rows"))
          success <- TRUE
          break
        }
      }, error = function(e) {
        message(paste("  Attempt", attempt, "failed:", conditionMessage(e)))
      })
    }
    
    if (!success) {
      message(paste("  FAILED:", name))
      yahooData[[name]] <- NA
    }
  }
  
  valid_data <- yahooData[!sapply(yahooData, is.null)]
  if (length(valid_data) > 0) {
    write.xlsx(valid_data, file.path(OUTPUT_DIR, "data.xlsx"), overwrite = TRUE)
  }
  
  eTime <- Sys.time()
  message(paste("Download completed in", round(eTime - sTime, 2), "seconds"))
  invisible(yahooData)
}

# =============================================================================
# Data Analysis - 修复slider错误
# =============================================================================

DataAnalysis <- function(tickers) {
  for (i in 1:nrow(tickers)) {
    name <- tickers$name[i]
    message(paste(name, ": started analysis..."))
    
    tryCatch({
      data_file <- file.path(OUTPUT_DIR, "data.xlsx")
      if (!file.exists(data_file)) {
        message("  ERROR: data.xlsx not found")
        next
      }
      
      all_sheets <- getSheetNames(data_file)
      if (!(name %in% all_sheets)) {
        message(paste("  ERROR: Sheet", name, "not found"))
        next
      }
      
      data <- read.xlsx(data_file, sheet = name)
      if (is.null(data) || nrow(data) == 0) {
        message("  ERROR: No data")
        next
      }
      
      data <- data %>%
        select(Date, Last, High, Low)
      data$Date <- as.Date(data$Date, origin = "1899-12-30")
      data <- na.omit(data)
      
      if (nrow(data) <= dataCheck) {
        message(paste("  SKIP: Insufficient data (", nrow(data), "rows)"))
        next
      }
      
      # 核心计算 - 修复slider错误
      data <- data %>%
        mutate(
          LastHistRank = percent_rank(Last),
          LastRollRank = slider::slide_dbl(Last, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE)
        ) %>%
        mutate(
          Range = High - Low,
          RangePerc = Range / lag(Last),
          Return = Last / lag(Last) - 1
        ) %>%
        mutate(
          HistMax = cummax(High),
          HistMin = cummin(Low)
        ) %>%
        mutate(
          ToHistMax = (HistMax - Last) / Last,
          ToHistMin = (HistMin - Last) / Last,
          HistDrawDown = (Last - HistMax) / HistMax,
          HistDrawDownHistRank = percent_rank(HistDrawDown),
          HistDrawDownRollRank = slider::slide_dbl(HistDrawDown, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE),
          HistDrawUp = (Last - HistMin) / HistMin,
          HistDrawUpHistRank = percent_rank(HistDrawUp),
          HistDrawUpRollRank = slider::slide_dbl(HistDrawUp, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE)
        )
      
      data <- data %>%
        mutate(
          ATR = zoo::rollapply(Range, ATRCalWindow, mean, fill = NA, align = "right"),
          ATRPerc = zoo::rollapply(RangePerc, ATRCalWindow, mean, fill = NA, align = "right"),
          DVol = zoo::rollapply(Return, VolCalWindow, sd, fill = NA, align = "right")
        )
      
      data$LongVaRPerc <- zoo::rollapply(data$Return, VaRCalWindow, 
                                         function(x) quantile(x, extremeCut[1], na.rm = TRUE), 
                                         fill = NA, align = "right")
      data$ShortVaRPerc <- zoo::rollapply(data$Return, VaRCalWindow, 
                                          function(x) quantile(x, extremeCut[2], na.rm = TRUE), 
                                          fill = NA, align = "right")
      
      data <- data %>%
        mutate(
          RangePercHistRank = percent_rank(RangePerc),
          RangePercRollRank = slider::slide_dbl(RangePerc, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE),
          ATRPercHistRank = percent_rank(ATRPerc),
          ATRPercRollRank = slider::slide_dbl(ATRPerc, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE),
          DVolHistRank = percent_rank(DVol),
          DVolRollRank = slider::slide_dbl(DVol, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE)
        )
      
      data <- data %>%
        mutate(
          RollMax = zoo::rollapply(High, RollWindow, max, fill = NA, align = "right"),
          RollMin = zoo::rollapply(Low, RollWindow, min, fill = NA, align = "right")
        ) %>%
        mutate(
          RollDrawDown = Last / RollMax - 1,
          RollDrawUp = Last / RollMin - 1,
          RollDrawDownHistRank = percent_rank(RollDrawDown),
          RollDrawDownRollRank = slider::slide_dbl(RollDrawDown, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE),
          RollDrawUpHistRank = percent_rank(RollDrawUp),
          RollDrawUpRollRank = slider::slide_dbl(RollDrawUp, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE)
        )
      
      data <- data %>%
        mutate(
          EMA5 = maFun(Last, n = maParameters[1]),
          EMA21 = maFun(Last, n = maParameters[2]),
          EMA89 = maFun(Last, n = maParameters[3]),
          EMA144 = maFun(Last, n = maParameters[4])
        ) %>%
        mutate(
          EMADev5 = Last / EMA5 - 1,
          EMADev21 = Last / EMA21 - 1,
          EMADev89 = Last / EMA89 - 1,
          EMADev144 = Last / EMA144 - 1,
          EMA_MADev_5_21 = EMA5 / EMA21 - 1,
          EMADev89HistRank = percent_rank(EMADev89),
          EMADev89RollRank = slider::slide_dbl(EMADev89, ~ tail(percent_rank(.x), 1), .before = RollWindow - 1, .complete = TRUE)
        )
      
      for (j in 1:length(ChgPeriod)) {
        period <- ChgPeriod[j]
        chg_col <- paste0("Chg", period, "DPerc")
        sigma_col <- paste0("Sigma", period, "D")
        
        data[[chg_col]] <- c(rep(NA, period), diff(data$Last, period) / lag(data$Last, period)[(period + 1):nrow(data)])
        data[[sigma_col]] <- data[[chg_col]] / (data$DVol * sqrt(period))
      }
      
      output_cols <- c("Date", "Last", "High", "Low", "Return",
                       "Range", "RangePerc", "ATR", "ATRPerc", "DVol",
                       "LongVaRPerc", "ShortVaRPerc",
                       "RangePercHistRank", "RangePercRollRank",
                       "ATRPercHistRank", "ATRPercRollRank",
                       "DVolHistRank", "DVolRollRank",
                       "LastHistRank", "LastRollRank",
                       "EMA5", "EMA21", "EMA89", "EMA144",
                       "EMADev5", "EMADev21", "EMADev89", "EMADev144", "EMA_MADev_5_21",
                       "EMADev89HistRank", "EMADev89RollRank",
                       "HistMax", "HistMin", "ToHistMax", "ToHistMin",
                       "HistDrawDown", "HistDrawUp",
                       "HistDrawDownHistRank", "HistDrawDownRollRank", "HistDrawUpHistRank", "HistDrawUpRollRank",
                       "RollMax", "RollMin",
                       "RollDrawDown", "RollDrawUp",
                       "RollDrawDownHistRank", "RollDrawDownRollRank", "RollDrawUpHistRank", "RollDrawUpRollRank")
      
      for (period in ChgPeriod) {
        output_cols <- c(output_cols, paste0("Chg", period, "DPerc"), paste0("Sigma", period, "D"))
      }
      
      for (col in output_cols) {
        if (!(col %in% names(data))) {
          data[[col]] <- NA
        }
      }
      
      data <- data[, output_cols]
      
      write.xlsx(data, file.path(DATA_ANALYSIS_DIR, paste0(name, "_DataAnalysis.xlsx")), overwrite = TRUE)
      message(paste("  SAVED:", name, "_DataAnalysis.xlsx"))
      
    }, error = function(e) {
      message(paste("  ERROR analyzing", name, ":", conditionMessage(e)))
    })
  }
}

# =============================================================================
# Data Report
# =============================================================================

DataReport <- function(tickers) {
  message("Generating report...")
  
  template_file <- file.path(DATA_ANALYSIS_DIR, "BTCUSD_DataAnalysis.xlsx")
  if (!file.exists(template_file)) {
    available_files <- list.files(DATA_ANALYSIS_DIR, pattern = "_DataAnalysis.xlsx$", full.names = TRUE)
    if (length(available_files) == 0) {
      message("ERROR: No DataAnalysis files found")
      return()
    }
    template_file <- available_files[1]
  }
  
  template_data <- read.xlsx(template_file)
  fields <- colnames(template_data)[-1]
  
  results <- data.frame(matrix(nrow = 0, ncol = length(fields) + 1))
  colnames(results) <- c("Name", fields)
  
  for (i in 1:nrow(tickers)) {
    name <- tickers$name[i]
    message(paste("Report - Fetching:", name))
    
    file_path <- file.path(DATA_ANALYSIS_DIR, paste0(name, "_DataAnalysis.xlsx"))
    if (!file.exists(file_path)) {
      message(paste("  SKIP: File not found"))
      next
    }
    
    tryCatch({
      data <- read.xlsx(file_path)
      if (nrow(data) == 0) {
        message(paste("  SKIP: Empty data"))
        next
      }
      
      last_row <- data[nrow(data), -1]
      
      new_row <- c(name, as.list(last_row))
      results[nrow(results) + 1, ] <- new_row
      message(paste("  ADDED:", name))
      
    }, error = function(e) {
      message(paste("  ERROR:", name, conditionMessage(e)))
    })
  }
  
  for (i in 2:ncol(results)) {
    results[, i] <- as.numeric(as.character(results[, i]))
  }
  
  results <- na.omit(results)
  
  write.xlsx(results, file.path(OUTPUT_DIR, paste0(eDate, "_AnalysisReport_plain.xlsx")), overwrite = TRUE)
  write.csv(results, file.path(OUTPUT_DIR, paste0(eDate, "_AnalysisReport_plain.csv")), row.names = FALSE)
  
  template_wb <- file.path(INPUT_DIR, "template_AnalysisReport.xlsx")
  if (file.exists(template_wb)) {
    wb <- loadWorkbook(template_wb)
    writeData(wb, sheet = 1, x = results, startRow = 4, startCol = 1, colNames = FALSE)
    saveWorkbook(wb, file.path(OUTPUT_DIR, "AnalysisReport_formal.xlsx"), overwrite = TRUE)
    message("Formal report saved: AnalysisReport_formal.xlsx")
  } else {
    message("WARNING: template_AnalysisReport.xlsx not found, using plain version")
    write.xlsx(results, file.path(OUTPUT_DIR, "AnalysisReport_formal.xlsx"), overwrite = TRUE)
  }
  
  message(paste("Report completed:", nrow(results), "instruments"))
}

# =============================================================================
# Data Visualization - 静态图表版 (PNG/PDF，不依赖pandoc)
# =============================================================================

DataVisualization <- function(tickers) {
  message("Creating static charts (PNG format)...")
  
  for (name in tickers$name) {
    file_path <- file.path(DATA_ANALYSIS_DIR, paste0(name, "_DataAnalysis.xlsx"))
    if (!file.exists(file_path)) {
      message(paste("  SKIP:", name, "- File not found"))
      next
    }
    
    tryCatch({
      data <- read.xlsx(file_path)
      data$Date <- as.Date(data$Date, origin = "1899-12-30")
      data <- data %>% filter(!is.na(Last))
      
      if (nrow(data) < 30) {
        message(paste("  SKIP:", name, "- Insufficient data"))
        next
      }
      
      # 取最近252个交易日（约1年）用于图表
      chart_data <- tail(data, 252)
      
      # 图1: 价格与均线
      p1 <- ggplot(chart_data, aes(x = Date)) +
        geom_line(aes(y = Last, color = "Price"), linewidth = 0.8) +
        geom_line(aes(y = EMA5, color = "EMA5"), linewidth = 0.5, linetype = "dashed") +
        geom_line(aes(y = EMA21, color = "EMA21"), linewidth = 0.5, linetype = "dashed") +
        geom_line(aes(y = EMA89, color = "EMA89"), linewidth = 0.6) +
        scale_color_manual(values = c("Price" = "black", "EMA5" = "red", "EMA21" = "blue", "EMA89" = "green")) +
        labs(title = paste(name, "- Price & Moving Averages"), 
             subtitle = paste("Last:", round(tail(chart_data$Last, 1), 2)),
             y = "Price", x = "") +
        theme_minimal() +
        theme(legend.position = "bottom")
      
      # 图2: 收益率分布
      p2 <- ggplot(chart_data, aes(x = Date)) +
        geom_line(aes(y = Chg5DPerc * 100, color = "5D"), linewidth = 0.5) +
        geom_line(aes(y = Chg20DPerc * 100, color = "20D"), linewidth = 0.5) +
        geom_hline(yintercept = 0, linetype = "dotted") +
        scale_color_manual(values = c("5D" = "blue", "20D" = "orange")) +
        labs(title = "Returns (%)", y = "Return (%)", x = "") +
        theme_minimal() +
        theme(legend.position = "bottom")
      
      # 图3: 波动率
      p3 <- ggplot(chart_data, aes(x = Date)) +
        geom_line(aes(y = DVol * 100, color = "Daily Vol"), linewidth = 0.6) +
        geom_line(aes(y = ATRPerc * 100, color = "ATR%"), linewidth = 0.6) +
        scale_color_manual(values = c("Daily Vol" = "red", "ATR%" = "purple")) +
        labs(title = "Volatility (%)", y = "Volatility (%)", x = "") +
        theme_minimal() +
        theme(legend.position = "bottom")
      
      # 图4: 回撤
      p4 <- ggplot(chart_data, aes(x = Date)) +
        geom_line(aes(y = HistDrawDown * 100), color = "red", linewidth = 0.6) +
        geom_area(aes(y = HistDrawDown * 100), fill = "red", alpha = 0.3) +
        labs(title = "Historical Drawdown (%)", y = "Drawdown (%)", x = "") +
        theme_minimal()
      
      # 组合图表并保存
      combined <- grid.arrange(p1, p2, p3, p4, ncol = 2, 
                               top = paste(name, "-", eDate, "| Technical Analysis"))
      
      # 保存PNG
      png_file <- file.path(CHARTING_DIR, paste0(name, "_", eDate, ".png"))
      ggsave(png_file, combined, width = 12, height = 10, dpi = 150)
      message(paste("  SAVED PNG:", png_file))
      
      # 保存PDF
      pdf_file <- file.path(CHARTING_DIR, paste0(name, "_", eDate, ".pdf"))
      ggsave(pdf_file, combined, width = 12, height = 10)
      message(paste("  SAVED PDF:", pdf_file))
      
      # 清理内存
      rm(chart_data, p1, p2, p3, p4, combined)
      gc()
      
    }, error = function(e) {
      message(paste("  ERROR:", name, "-", conditionMessage(e)))
    })
  }
  
  message("Charts completed!")
}

# =============================================================================
# Main
# =============================================================================

main <- function() {
  message("============================================")
  message("Market Analytics Pipeline - Static Charts Version")
  message(paste("Date:", eDate))
  message("============================================")
  
  tickers_file <- file.path(INPUT_DIR, "tickers_macro.xlsx")
  if (!file.exists(tickers_file)) {
    message("FATAL ERROR: tickers_macro.xlsx not found!")
    return()
  }
  
  instruments <- read.xlsx(tickers_file)
  message(paste("Loaded", nrow(instruments), "instruments"))
  
  message("\nStep 1/4: Downloading data...")
  yahooDownload(instruments, sDate, eDate)
  
  message("\nStep 2/4: Analyzing data...")
  DataAnalysis(instruments)
  
  message("\nStep 3/4: Generating report...")
  DataReport(instruments)
  
  message("\nStep 4/4: Creating static charts...")
  DataVisualization(instruments)
  
  message("\n============================================")
  message("Pipeline Completed!")
  message("Output files:")
  message(paste("  - Excel reports:", OUTPUT_DIR))
  message(paste("  - Charts (PNG/PDF):", CHARTING_DIR))
  message("============================================")
}

main()
