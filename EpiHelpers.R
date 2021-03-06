predData <- function(rd, distr, level, wind = NA, projper = 0, deltar = NA, deltardate = NA) {
  if(any(is.na(wind))) wind <- c(rd$NumDate[1]+1, tail(rd$NumDate,1)+1)
  if(projper>0) rd <- rbind(rd, data.table(Date = seq.Date(tail(rd$Date,1), tail(rd$Date,1)+projper, by = "days"),
                                           CaseNumber = NA, DeathNumber = NA, CumCaseNumber = NA, CumDeathNumber = NA,
                                           NumDate = tail(rd$NumDate,1):(tail(rd$NumDate,1)+projper)))
  rd$Deviated <- (rd$Date >= deltardate)&is.na(rd$CaseNumber)
  crit.value <- qt(1-(1-level/100)/2, df = sum(!is.na(rd$CaseNumber))-2)
  if(distr=="Lognormális") {
    m <- lm(log(CaseNumber) ~ Date, data = rd[CaseNumber!=0], subset = NumDate>=(wind[1]-1)&NumDate<=(wind[2]-1))
  } else if(distr=="Poisson") {
    m <- glm(CaseNumber ~ Date, data = rd, subset = NumDate>=(wind[1]-1)&NumDate<=(wind[2]-1), family = poisson(link = "log"))
  } else if(distr=="Negatív binomiális") {
    m <- MASS::glm.nb(CaseNumber ~ Date, data = rd, subset = NumDate>=(wind[1]-1)&NumDate<=(wind[2]-1))
  }
  if(!is.na(deltar)) m <- update(m, formula = as.formula(paste0(".~.+offset(", deltar, "*Deviated*(NumDate-",
                                                                sum(!rd$Deviated)-1,"))")))
  pred <- data.table(rd, with(predict(m, newdata = rd, se.fit = TRUE),
                              data.table(fit = exp(fit), lwr = exp(fit - (crit.value * se.fit)),
                                         upr = exp(fit + (crit.value * se.fit)))))
  list(pred = pred, m = m)
}

r2R0gamma <- function(r, si_mean, si_sd) {
  (1+r*si_sd^2/si_mean)^(si_mean^2/si_sd^2)
}

lm2R0gamma_sample <- function(x, si_mean, si_sd, n = 1000) {
  df <- nrow(x$model) - 2
  r <- x$coefficients[2]
  std_r <- stats::coef(summary(x))[, "Std. Error"][2]
  r_sample <- r + std_r * stats::rt(n, df)
  r2R0gamma(r_sample, si_mean, si_sd)
}

round_dt <- function(dt, digits = 2) as.data.table(dt, keep.rownames = TRUE)[, lapply(.SD, function(x)
  if(is.numeric(x)&!is.integer(x)) format(round(x, digits), nsmall = digits, trim = TRUE) else x)]

epicurvePlot <- function(pred, logy, expfit, loessfit, ci, conf, delta = FALSE, deltadate = NA) {
  ggplot(pred, aes(x = Date, y = CaseNumber)) + geom_point(size = 3) + labs(x = "Dátum", y = "Napi esetszám [fő/nap]") +
    {if(logy) scale_y_log10()} + {if(expfit) geom_line(aes(y = fit, color = is.na(CaseNumber)), show.legend = FALSE)} +
    {if(expfit&ci) geom_ribbon(aes(y = fit, ymin = lwr, ymax = upr, fill = is.na(CaseNumber)),
                               alpha = 0.2, show.legend = FALSE)} +
    {if(loessfit) geom_smooth(formula = y ~ x, method = "loess", col = "blue", se = ci,
                              fill = "blue", alpha = 0.2, level = conf/100, size = 0.5)} +
    {if(delta) geom_vline(xintercept = deltadate)}
}

grText <- function(m, deltar = 0, future = FALSE, deltarDate = NA) {
  paste0(if(future) paste0( "A jövőbeli növekedési ráta ", deltarDate, " dátumtól ")  else 
    "A fenti exponenciális illesztéssel a növekedési ráta ", round_dt(coef(m)+deltar)[rn=="Date", -"rn"], " (95%-os CI: ",
    paste0(round_dt(confint(m)+deltar)[rn=="Date", -"rn"], collapse = " - "),
    "). Ez azt jelenti, hogy a duplázódási idő (az ahhoz szükséges idő, hogy a napi esetszám kétszeresére nőjön) ",
    round_dt(log(2)/(coef(m)+deltar))[rn=="Date", -"rn"], " nap (95%-os CI: ",
    paste0(rev(round_dt(log(2)/(confint(m)+deltar))[rn=="Date", -"rn"]), collapse = " - "), ").")
}

grData <- function(m, SImu, SIsd) {
  data.frame(R = lm2R0gamma_sample(m, SImu, SIsd))
}

grSwData <- function(rd, ms, SImu, SIsd, windowlen) {
  res <- lapply(ms, function(m) lm2R0gamma_sample(m, SImu, SIsd))
  res <- data.table(do.call(rbind, lapply(res, function(x)
    c(mean(x, na.rm = TRUE), quantile(x, c(0.025, 0.975), na.rm = TRUE)))), check.names = TRUE)
  res$Date <- rd$Date[windowlen:nrow(rd)]
  res
}

branchData <- function(rd, SImu, SIsd, wind = NA) {
  if(is.na(wind)) wind <- c(max(c(2, rd$NumDate[1]+1)), tail(rd$NumDate,1)+1)
  data.table(R = EpiEstim::sample_posterior_R(EpiEstim::estimate_R(
    rd$CaseNumber, method = "parametric_si",
    config = EpiEstim::make_config(list(mean_si = SImu, std_si = SIsd, t_start = wind[1], t_end = wind[2])))))
}

branchSwData <- function(rd, SImu, SIsd, windowlen) {
  res <- EpiEstim::estimate_R(rd$CaseNumber, method = "parametric_si",
                              config = EpiEstim::make_config(list(
                                t_start = seq(2, nrow(rd)-windowlen+1), t_end = (2+windowlen-1):nrow(rd),
                                mean_si = SImu, std_si = SIsd)))$R
  res$Date <- rd$Date[(windowlen+1):nrow(rd)]
  res
}

cfrData <- function(rd, HDTmu, HDTsd, conf) {
  res <- data.table(t(mapply(function(...) with(binom.test(...), c(estimate, conf.int)),
                             rd$CumDeathNumber, rd$CumCaseNumber, MoreArgs = list(conf.level = conf/100))))
  names(res) <- c("value", "lwr", "upr")
  res$`Típus` <- "Nyers"
  res$Date <- rd$Date
  discrdist <- distcrete::distcrete("lnorm", 1, meanlog = log(HDTmu)-log(HDTsd^2/HDTmu^2+1)/2,
                                    sdlog = sqrt(log(HDTsd^2/HDTmu^2+1)))
  mll <- function(p, t, rd) {
    -dbinom(rd$CumDeathNumber[t],round(sum(sapply(1:t, function(i)
      sum(sapply(0:(i-1), function(j) rd$CaseNumber[i-j]*discrdist$d(j)))))), p, log = TRUE)
  }
  res2<-data.table(t(sapply(14:nrow(rd), function(s) {
    temp <- bbmle::mle2(mll, list(p = 0.01), data = list(rd = rd, t = s), method = "Brent",
                        lower = 1e-10, upper = 1-1e-10)
    c(temp@coef,bbmle::confint(bbmle::profile(temp), "p", conf/100))
  })))
  names(res2) <- c("value", "lwr", "upr")
  res2$`Típus` <- "Korrigált"
  res2$Date <- rd[14:nrow(rd)]$Date
  rbind(res,res2)
}