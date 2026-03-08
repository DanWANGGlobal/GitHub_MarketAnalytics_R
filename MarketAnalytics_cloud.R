#!/usr/bin/env Rscript
# Cloud-Ready Market Analytics Script - 完整版
# 保留所有原始输出字段

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
  message(paste("Downloading data for", nrow(tickers), "tickers..."))
  sTime <- Sys.time()
  yahooData <- list()
  
  for (i in 1:nrow(tickers)) {
    symbol <- tickers$ticker[i]
    name <- tickers$name[i]
    
    message(paste("[", i, "/", nrow(tickers), "] Downloading:", name, "(", symbol, ")"))
    
    success <- FALSE
    for (attempt in 1:3) {
      if (attempt > 1) {
        message(paste("Retry attempt", attempt))
        Sys.sleep(2)
      }
      
      tryCatch({
        data <- getSymbols(symbol, from = sDate, to = eDate, 
                          src = "yahoo", auto.assign = FALSE)
        
        if (!is.null(data) && nrow(data) > 0) {
          message(paste("Got data for", name, "- rows:", nrow(data)))
          
          df <- xts_to_tbl(data)
          colnames(df) <- c("Open", "High", "Low", "Close", "Volume", "Last", "Date")
          df <- df[, c("Date", "Open", "High", "Low", "Close", "Volume", "Last")]
          yahooData[[name]] <- df
          
          message(paste("SUCCESS:", name, "-", nrow(df), "rows"))
          success <- TRUE
          break
        }
      }, error = function(e) {
        message(paste("Attempt", attempt, "failed:", conditionMessage(e)))
      })
    }
    
    if (!success) {
      message(paste("FAILED after 3 attempts:", name))
    }
  }
  
  eTime <- Sys.time()
  message(paste("Download completed in", round(eTime - sTime, 2), "seconds"))
  message(paste("Successfully downloaded:", length(yahooData), "/", nrow(tickers), "instruments"))
  
  if (length(yahooData) > 0) {
    write.xlsx(yahooData, file.path(OUTPUT_DIR, "data.xlsx"), overwrite = TRUE)
  }
  
  invisible(yahooData)
}

# =============================================================================
# Data Analysis - 完整版
# =============================================================================

DataAnalysis <- function(tickers) {
  message("Starting data analysis...")
  
  data_file <- file.path(OUTPUT_DIR, "data.xlsx")
  if (!file.exists(data_file)) {
    message("ERROR: data.xlsx not found!")
    return(NULL)
  }
  
  sheet_names <- getSheetNames(data_file)
  message(paste("Found sheets:", paste(sheet_names, collapse = ", ")))
  
  for (name in sheet_names) {
    message(paste("Analyzing:", name))
    
    tryCatch({
      data <- read.xlsx(data_file, sheet = name)
      
      if (is.null(data) || nrow(data) < dataCheck) {
        message(paste("Skip:", name, "- insufficient data"))
        next
      }
      
      # 基础数据处理
      data$Date <- as.Date(data$Date)
      data <- data %>% arrange(Date)
      data <- data %>% filter(!is.na(Last), !is.na(High), !is.na(Low))
      
      if (nrow(data) < dataCheck) {
        message(paste("Skip:", name, "- after NA removal:", nrow(data), "rows"))
        next
      }
      
      # 基础指标计算
      data$Return <- c(NA, diff(data$Last) / head(data$Last, -1))
      data$LogReturn <- c(NA, diff(log(data$Last)))
      
      # 移动平均线
      for (ma in maParameters) {
        data[[paste0("MA", ma)]] <- EMA(data$Last, n = ma)
      }
      
      # 偏差计算
      data$Dev5 <- data$Last / data$MA5 - 1
      data$Dev21 <- data$Last / data$MA21 - 1
      data$Dev89 <- data$Last / data$MA89 - 1
      data$Dev144 <- data$Last / data$MA144 - 1
      
      # 波动率
      data$Range <- data$High - data$Low
      data$ATR <- zoo::rollapply(data$Range, ATRCalWindow, mean, fill = NA, align = "right")
      data$DVol <- zoo::rollapply(data$Return, VolCalWindow, sd, fill = NA, align = "right")
      data$AnnualVol <- data$DVol * sqrt(252)
      
      # 收益率计算
      for (period in ChgPeriod) {
        data[[paste0("Chg", period)]] <- calc_roc(data$Last, period)
      }
      
      # RSI
      data$RSI <- RSI(data$Last, n = 14)
      
      # MACD
      macd <- MACD(data$Last, nFast = 12, nSlow = 26, nSig = 9)
      data$MACD <- macd[, "macd"]
      data$MACDsignal <- macd[, "signal"]
      data$MACDhist <- macd[, "macd"] - macd[, "signal"]
      
      # 布林带
      bb <- BBands(data$Last, n = 20, sd = 2)
      data$BBdn <- bb[, "dn"]
      data$BBmavg <- bb[, "mavg"]
      data$BBup <- bb[, "up"]
      data$BBpctB <- bb[, "pctB"]
      
      # 成交量指标
      data$VolMA20 <- zoo::rollapply(data$Volume, 20, mean, fill = NA, align = "right")
      data$VolRatio <- data$Volume / data$VolMA20
      
      # 高低点
      data$HH20 <- zoo::rollapply(data$High, 20, max, fill = NA, align = "right")
      data$LL20 <- zoo::rollapply(data$Low, 20, min, fill = NA, align = "right")
      data$HH60 <- zoo::rollapply(data$High, 60, max, fill = NA, align = "right")
      data$LL60 <- zoo::rollapply(data$Low, 60, min, fill = NA, align = "right")
      
      # 分位数排名
      data$PctRankVol <- run_pct_rank(data$DVol, 250)
      data$PctRankRSI <- run_pct_rank(data$RSI, 250)
      data$PctRankDev89 <- run_pct_rank(abs(data$Dev89), 250)
      
      # 信号生成
      data$LongSignal <- ifelse(data$Dev89 < -0.15 & data$RSI < 40, 1, 0)
      data$ShortSignal <- ifelse(data$Dev89 > 0.15 & data$RSI > 60, 1, 0)
      data$HighVolSignal <- ifelse(data$PctRankVol > 0.85, 1, 0)
      data$LowVolSignal <- ifelse(data$PctRankVol < 0.15, 1, 0)
      
      # 趋势转换
      data$UpToDown <- ifelse(lag(data$Last) > lag(data$MA21) & data$Last < data$MA21, 1, 0)
      data$DownToUp <- ifelse(lag(data$Last) < lag(data$MA21) & data$Last > data$MA21, 1, 0)
      
      write.xlsx(data, file.path(DATA_ANALYSIS_DIR, paste0(name, "_DataAnalysis.xlsx")), overwrite = TRUE)
      message(paste("Analyzed:", name))
      
    }, error = function(e) {
      message(paste("Error analyzing", name, ":", conditionMessage(e)))
    })
  }
  
  message("Analysis completed!")
}

# =============================================================================
# Data Report - 完整版（恢复所有原始字段）
# =============================================================================

DataReport <- function(tickers) {
  message("Generating comprehensive report...")
  results <- list()
  
  for (name in tickers$name) {
    file <- file.path(DATA_ANALYSIS_DIR, paste0(name, "_DataAnalysis.xlsx"))
    if (!file.exists(file)) {
      message(paste("File not found:", file))
      next
    }
    
    tryCatch({
      data <- read.xlsx(file)
      if (nrow(data) == 0) {
        message(paste("Empty data for:", name))
        next
      }
      
      # 获取最后一行数据
      last <- tail(data, 1)
      
      # 构建完整的结果行（匹配原始报告格式）
      result <- data.frame(
        # 基础信息
        Name = name,
        Ticker = tickers$ticker[tickers$name == name],
        
        # 价格数据
        Last = safe_last(data$Last),
        Open = safe_last(data$Open),
        High = safe_last(data$High),
        Low = safe_last(data$Low),
        
        # 收益指标
        Return = safe_last(data$Return),
        LogReturn = safe_last(data$LogReturn),
        Chg5 = safe_last(data$Chg5),
        Chg20 = safe_last(data$Chg20),
        Chg60 = safe_last(data$Chg60),
        Chg120 = safe_last(data$Chg120),
        Chg180 = safe_last(data$Chg180),
        Chg250 = safe_last(data$Chg250),
        
        # 移动平均线
        MA5 = safe_last(data$MA5),
        MA21 = safe_last(data$MA21),
        MA89 = safe_last(data$MA89),
        MA144 = safe_last(data$MA144),
        
        # 偏差
        Dev5 = safe_last(data$Dev5),
        Dev21 = safe_last(data$Dev21),
        Dev89 = safe_last(data$Dev89),
        Dev144 = safe_last(data$Dev144),
        
        # 波动率
        DVol = safe_last(data$DVol),
        AnnualVol = safe_last(data$AnnualVol),
        ATR = safe_last(data$ATR),
        
        # 技术指标
        RSI = safe_last(data$RSI),
        MACD = safe_last(data$MACD),
        MACDsignal = safe_last(data$MACDsignal),
        MACDhist = safe_last(data$MACDhist),
        
        # 布林带
        BBdn = safe_last(data$BBdn),
        BBmavg = safe_last(data$BBmavg),
        BBup = safe_last(data$BBup),
        BBpctB = safe_last(data$BBpctB),
        
        # 成交量
        Volume = safe_last(data$Volume),
        VolMA20 = safe_last(data$VolMA20),
        VolRatio = safe_last(data$VolRatio),
        
        # 高低点
        HH20 = safe_last(data$HH20),
        LL20 = safe_last(data$LL20),
        HH60 = safe_last(data$HH60),
        LL60 = safe_last(data$LL60),
        
        # 分位数
        PctRankVol = safe_last(data$PctRankVol),
        PctRankRSI = safe_last(data$PctRankRSI),
        PctRankDev89 = safe_last(data$PctRankDev89),
        
        # 信号
        Long = safe_last(data$LongSignal),
        Short = safe_last(data$ShortSignal),
        HighVol = safe_last(data$HighVolSignal),
        LowVol = safe_last(data$LowVolSignal),
        UpToDown = safe_last(data$UpToDown),
        DownToUp = safe_last(data$DownToUp),
        
        # 日期
        Date = safe_last(data$Date),
        
        stringsAsFactors = FALSE
      )
      
      results[[name]] <- result
      message(paste("Added to report:", name))
      
    }, error = function(e) {
      message(paste("Error processing", name, ":", conditionMessage(e)))
    })
  }
  
  if (length(results) > 0) {
    report <- do.call(rbind, results)
    
    # 添加元数据列（匹配原始报告格式）
    report$`微信公众号【TraderX-Flow】` <- "TraderX-Flow"
    
    # 重新排列列顺序
    col_order <- c("微信公众号【TraderX-Flow】", "Name", "Ticker", "Date", 
                   "Last", "Open", "High", "Low",
                   "Return", "LogReturn", "Chg5", "Chg20", "Chg60", "Chg120", "Chg180", "Chg250",
                   "MA5", "MA21", "MA89", "MA144",
                   "Dev5", "Dev21", "Dev89", "Dev144",
                   "DVol", "AnnualVol", "ATR",
                   "RSI", "MACD", "MACDsignal", "MACDhist",
                   "BBdn", "BBmavg", "BBup", "BBpctB",
                   "Volume", "VolMA20", "VolRatio",
                   "HH20", "LL20", "HH60", "LL60",
                   "PctRankVol", "PctRankRSI", "PctRankDev89",
                   "Long", "Short", "HighVol", "LowVol", "UpToDown", "DownToUp")
    
    # 确保所有列都存在
    for (col in col_order) {
      if (!col %in% names(report)) {
        report[[col]] <- NA
      }
    }
    
    report <- report[, col_order]
    
    output_file <- file.path(OUTPUT_DIR, paste0(eDate, "_AnalysisReport.xlsx"))
    write.xlsx(report, output_file, overwrite = TRUE)
    message(paste("Comprehensive report generated:", nrow(report), "instruments"))
    message(paste("Total columns:", ncol(report)))
  } else {
    message("No data for report")
  }
}

# =============================================================================
# Data Visualization - 修复版
# =============================================================================

DataVisualization <- function(tickers) {
  message("Creating charts...")
  
  for (name in tickers$name) {
    file <- file.path(DATA_ANALYSIS_DIR, paste0(name, "_DataAnalysis.xlsx"))
    if (!file.exists(file)) {
      message(paste("Analysis file not found:", name))
      next
    }
    
    tryCatch({
      Data <- read.xlsx(file)
      Data$Date <- as.Date(Data$Date)
      Data <- Data %>% filter(!is.na(Last), !is.na(Date))
      
      if (nrow(Data) < 30) {
        message(paste("Skip chart:", name, "- insufficient data"))
        next
      }
      
      # 获取最后180天的数据用于显示
      display_data <- tail(Data, 180)
      
      # 创建交互式图表
      p <- plot_ly(display_data, type = "scatter", mode = "lines")
      
      # 主价格线
      p <- p %>% add_trace(x = ~Date, y = ~Last, name = "Price", 
                           line = list(color = "black", width = 1.5))
      
      # 移动平均线
      if (any(!is.na(display_data$MA5))) {
        p <- p %>% add_trace(x = ~Date, y = ~MA5, name = "MA5", 
                             line = list(color = "blue", width = 1))
      }
      if (any(!is.na(display_data$MA21))) {
        p <- p %>% add_trace(x = ~Date, y = ~MA21, name = "MA21", 
                             line = list(color = "orange", width = 1))
      }
      if (any(!is.na(display_data$MA89))) {
        p <- p %>% add_trace(x = ~Date, y = ~MA89, name = "MA89", 
                             line = list(color = "red", width = 1.5))
      }
      
      # 布林带
      if (any(!is.na(display_data$BBup))) {
        p <- p %>% add_trace(x = ~Date, y = ~BBup, name = "BB Upper",
                             line = list(color = "gray", width = 0.5, dash = "dash"))
      }
      if (any(!is.na(display_data$BBdn))) {
        p <- p %>% add_trace(x = ~Date, y = ~BBdn, name = "BB Lower",
                             line = list(color = "gray", width = 0.5, dash = "dash"))
      }
      
      # 布局
      p <- p %>% layout(
        title = list(text = paste(name, "Technical Analysis"), font = list(size = 16)),
        xaxis = list(title = "Date", showgrid = TRUE),
        yaxis = list(title = "Price", showgrid = TRUE),
        legend = list(orientation = "h", y = -0.2),
        hovermode = "x unified"
      )
      
      # 保存为自包含HTML（确保可以离线打开）
      html_file <- file.path(CHARTING_DIR, paste0(Sys.Date(), "_", name, ".html"))
      htmlwidgets::saveWidget(p, html_file, selfcontained = TRUE, libdir = NULL)
      message(paste("Chart saved:", html_file))
      
    }, error = function(e) {
      message(paste("Chart error:", name, "-", conditionMessage(e)))
    })
  }
  
  message("Charts completed!")
}

# =============================================================================
# Main
# =============================================================================

main <- function() {
  message("============================================")
  message("Cloud Market Analytics Pipeline - Full Version")
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
  
  message("\nStep 3/4: Generating comprehensive report...")
  DataReport(instruments)
  
  message("\nStep 4/4: Creating visualizations...")
  DataVisualization(instruments)
  
  message("\n============================================")
  message("Pipeline Completed!")
  message("============================================")
}

main()
