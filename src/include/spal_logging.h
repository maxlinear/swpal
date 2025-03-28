/******************************************************************************

         Copyright (c) 2020, MaxLinear, Inc.
         Copyright 2016 - 2020 Intel Corporation

  For licensing information, see the file 'LICENSE' in the root folder of
  this software module.

*******************************************************************************/

/*  *****************************************************************************
 *         File Name    : spal_logging.h	                                    *
 *         Description  : header file for logging framework                     *
 *  *****************************************************************************/

#ifndef SPAL_LOGGING_H
#define SPAL_LOGGING_H

#ifndef USE_SYSLOG
#define USE_SYSLOG      1   /*!< Macro for using syslog */
#endif

#ifndef DBG_TIMESTAMP
#define DBG_TIMESTAMP   1   /*!< Macro for debug timestamp */
#endif

#include<stdio.h>
#include<stdint.h>
#include<stdarg.h>
#ifdef USE_SYSLOG
#include<syslog.h>
#endif /*USE_SYSLOG*/
#ifdef DBG_TIMESTAMP
#include <sys/time.h>
#include <time.h>
#endif /*DBG_TIMESTAMP*/

/*! \file spal_logging.h
 \brief File contains macros and enums for logging debug messages
*/

/** \addtogroup SYSFRAMEWORK_LOG */
/* @{ */

#ifndef PACKAGE_ID
#error "Please define PACKAGE_ID"
#endif /*PACKAGE_ID*/

#define COLOR_NRM  "\x1B[0m"
#define COLOR_RED  "\x1B[31m"
#define COLOR_GRN  "\x1B[32m"
#define COLOR_YEL  "\x1B[33m"
#define COLOR_BLU  "\x1B[34m"
#define COLOR_MAG  "\x1B[35m"
#define COLOR_CYN  "\x1B[36m"
#define COLOR_WHT  "\x1B[37m"
#define COLOR_ORA  "\x1B[38;5;214m"

#define UGW_LOG_PROFILE     1

#ifdef USE_SYSLOG
#define SYS_LOG_EMERG       LOG_EMERG
#define SYS_LOG_ALERT       LOG_ALERT
#define SYS_LOG_CRIT        LOG_CRIT
#define SYS_LOG_ERR         LOG_ERR
#define SYS_LOG_WARNING     LOG_WARNING
#define SYS_LOG_NOTICE      LOG_NOTICE
#define SYS_LOG_INFO        LOG_INFO
#define SYS_LOG_DEBUG       LOG_DEBUG
#else /* USE_SYSLOG */
#define SYS_LOG_EMERG       0
#define SYS_LOG_ALERT       1
#define SYS_LOG_CRIT        2
#define SYS_LOG_ERR         3
#define SYS_LOG_WARNING     4
#define SYS_LOG_NOTICE      5
#define SYS_LOG_INFO        6
#define SYS_LOG_DEBUG       7
#endif /* USE_SYSLOG */

#define SYS_LOG_TYPE_NONE             0                 /*!< log type            */
#define SYS_LOG_TYPE_FILE             (1 << 0)          /*!< log type file       */
#define SYS_LOG_TYPE_CONSOLE          (1 << 1)          /*!< log type console    */
#define SYS_LOG_TYPE_FILE_AND_CONSOLE (SYS_LOG_TYPE_FILE | SYS_LOG_TYPE_CONSOLE)   /*!< log type both console and file    */


#ifdef __cplusplus
extern "C" {
#endif


#ifdef WAVEAPI_USE_EXTERN_LOG
/* Use thread var for log levels */
#define __LOGGER_THREADVAR __thread
#else
#define __LOGGER_THREADVAR
#endif

/* JS: toto: change below to uint16_t */
extern __LOGGER_THREADVAR unsigned int LOGPROFILE;
extern __LOGGER_THREADVAR unsigned int LOGLEVEL;
extern __LOGGER_THREADVAR unsigned int LOGTYPE;

static void LOGF_LOG_PRINT(const char *color_code, const char *logtype, const char *fmt, ...)
	__attribute__((format(printf, 3, 4))) /* Hint for GCC compiler to parse format string */
	__attribute__((unused)) /* To supress warning if log functions weren't called in the translation unit */;

#ifdef WAVEAPI_USE_EXTERN_LOG

#if defined YOCTO
#include <slibc/string.h>
#include <slibc/stdio.h>
#else
#include "libsafec/safe_str_lib.h"
#include "libsafec/safe_mem_lib.h"
#endif

typedef void (*waveapi_extern_log_print_t)(const char *str_buf);
extern waveapi_extern_log_print_t waveapi_extern_log_print_func;

typedef const char* (*waveapi_extern_ipc_client_name_t)(void);
extern waveapi_extern_ipc_client_name_t waveapi_extern_ipc_client_name_get;

static void LOGF_LOG_PRINT(const char *color_code, const char *logtype, const char *fmt, ...) {
		char dbg_str[4*1024];
		size_t buf_size = sizeof(dbg_str);
		char *pbuf = dbg_str;
		va_list args;
		int res;
#ifdef DBG_TIMESTAMP
		struct timeval tv;
		struct tm * timeinfo;
		time_t nowtime;
		char tmbuf[50]="\0";
		gettimeofday(&tv, NULL);
		nowtime = tv.tv_sec;
		timeinfo = localtime(&nowtime);
		if(timeinfo != NULL)
				strftime(tmbuf,50,"%d-%m-%Y %T", timeinfo);
		res = sprintf_s(pbuf, buf_size, "%s<%s> [%s] ",color_code, tmbuf, logtype);
#else
		res = sprintf_s(pbuf, buf_size, "%s[%s] ",color_code, logtype);
#endif
		if (res < 0)
			return;

		pbuf += res;
		buf_size -= res;

		do{
				va_start(args, fmt);
				res = vsprintf_s(pbuf, buf_size, fmt, args);
				va_end(args);
				if (res < 0)
					return;
				pbuf += res;
				buf_size -= res;
				res = sprintf_s(pbuf, buf_size, "%s",COLOR_NRM);
				if (res < 0)
					return;
				if (waveapi_extern_log_print_func)
					waveapi_extern_log_print_func(dbg_str);
				else {
					printf("%s", dbg_str);
					fflush(stdout);
				}
		}while(0);
}

#define LOGF_SYSLOG(prio, fmt, args...) \
	do { \
		if (waveapi_extern_ipc_client_name_get) \
			syslog(prio, "[%s]: " fmt, waveapi_extern_ipc_client_name_get(), ##args); \
		else \
			syslog(prio, fmt, ##args); \
	} while (0);

#else /* WAVEAPI_USE_EXTERN_LOG */

static void LOGF_LOG_PRINT(const char *color_code, const char *logtype, const char *fmt, ...) {
		va_list args;
#ifdef DBG_TIMESTAMP
		struct timeval tv;
		struct tm * timeinfo;
		time_t nowtime;
		char tmbuf[50]="\0";
		gettimeofday(&tv, NULL);
		nowtime = tv.tv_sec;
		timeinfo = localtime(&nowtime);
		if(timeinfo != NULL)
				strftime(tmbuf,50,"%d-%m-%Y %T", timeinfo);
		printf("%s<%s> [%s] ",color_code, tmbuf, logtype);
#else
		printf("%s[%s] ",color_code, logtype);
#endif
		do{
				va_start(args, fmt);
				vprintf(fmt, args);
				va_end(args);
				printf("%s",COLOR_NRM);
				fflush(stdout);
		}while(0);
}

#define LOGF_SYSLOG(prio, fmt, args...) syslog(prio, fmt, ##args);

#endif /* WAVEAPI_USE_EXTERN_LOG */

#ifdef USE_SYSLOG
#define LOGF_OPEN(sl_name) openlog(sl_name, LOG_CONS | LOG_PID | LOG_NDELAY, LOG_USER)  /*!< LOG OPEN */
#define LOGF_CLOSE()  closelog()		/*!< LOG CLOSE */
#endif

static inline void LOGF_MASK(int log_level) {
#if defined PROC_LEVEL && USE_SYSLOG
		if ( log_level >= SYS_LOG_EMERG && log_level <= SYS_LOG_DEBUG)
				setlogmask(LOG_UPTO(log_level));
		else
				setlogmask(LOG_UPTO(SYS_LOG_INFO));
#else
		LOGLEVEL = log_level;
#endif
}

static inline void LOGF_TYPE(int log_type) {
		LOGTYPE = log_type;
}

/* PACKAGE_ID will be provided by relevant package make file.  */
#define LOGF_LOG_PROFILE(args...)     PROFILE_PRINTF(INFO, ##args)    /*!< Macro to define profile logging  */
#define LOGF_LOG_ERROR(args...)       PRINTF(ERR, ##args)             /*!< Macro to define error level      */
#define LOGF_LOG_EMERG(args...)       PRINTF(EMERG, ##args)           /*!< Macro to define emergency level  */
#define LOGF_LOG_ALERT(args...)       PRINTF(ALERT, ##args)           /*!< Macro to define alert level      */
#define LOGF_LOG_CRITICAL(args...)    PRINTF(CRIT, ##args)            /*!< Macro to define critical level   */
#define LOGF_LOG_WARNING(args...)     PRINTF(WARNING, ##args)         /*!< Macro to define warning level    */
#define LOGF_LOG_NOTICE(args...)      PRINTF(NOTICE, ##args)          /*!< Macro to define notice level     */
#define LOGF_LOG_INFO(args...)        PRINTF(INFO, ##args)            /*!< Macro to define info level       */
#define LOGF_LOG_DEBUG(args...)       PRINTF(DEBUG, ##args)           /*!< Macro to define debug level      */
#define LOGF_LOG(LEVEL, fmt, args...) SYSLOG_##LEVEL(PACKAGE_ID "{%s, %d}: " fmt, __func__, __LINE__, ##args) /*!< PROFILE PRINTF Macro */

#define PRINTF(LEVEL, fmt, args...)   SYSLOG_##LEVEL(PACKAGE_ID "{%s, %d}: " fmt, __func__, __LINE__, ##args) /*!< PRINTF Macro */
#define PROFILE_PRINTF(LEVEL, fmt, args...)   UGWLOG_PROFILE(PACKAGE_ID "{%s, %d}: " fmt, __func__, __LINE__, ##args) /*!< PROFILE_PRINTF Macro */

/*Log-Helper-Functions defined in liblishelper*/
#define CRIT(fmt, args...)  LOGF_LOG_CRITICAL(fmt, ##args)
#define ERROR(fmt, args...) LOGF_LOG_ERROR(fmt, ##args)
#define WARN(fmt, args...)  LOGF_LOG_WARNING(fmt, ##args)
#define INFO(fmt, args...)  LOGF_LOG_INFO(fmt, ##args)
#define DEBUG(fmt, args...) LOGF_LOG_DEBUG(fmt, ##args)
/*END Log-Helper-Functions*/

#ifdef USE_SYSLOG

#define UGWLOG_PROFILE(fmt, args...) \
	do{ \
		if( UGW_LOG_PROFILE != LOGPROFILE) break; \
		if( LOGTYPE & SYS_LOG_TYPE_FILE) LOGF_SYSLOG(LOG_INFO, fmt, ##args); \
		if( LOGTYPE & SYS_LOG_TYPE_CONSOLE) LOGF_LOG_PRINT(COLOR_RED, "INFO", fmt, ##args); \
	}while(0);

#define SYSLOG_EMERG(fmt, args...) \
	do{ \
		if( SYS_LOG_EMERG > LOGLEVEL) break; \
		if( LOGTYPE & SYS_LOG_TYPE_FILE) LOGF_SYSLOG(LOG_EMERG, fmt, ##args); \
		if( LOGTYPE & SYS_LOG_TYPE_CONSOLE) LOGF_LOG_PRINT(COLOR_RED, "EMERG", fmt, ##args); \
	}while(0);

#define SYSLOG_ALERT(fmt, args...) \
	do{ \
		if( SYS_LOG_ALERT > LOGLEVEL) break; \
		if( LOGTYPE & SYS_LOG_TYPE_FILE) LOGF_SYSLOG(LOG_ALERT, fmt, ##args); \
		if( LOGTYPE & SYS_LOG_TYPE_CONSOLE) LOGF_LOG_PRINT(COLOR_RED, "ALERT", fmt, ##args); \
	}while(0);

#define SYSLOG_CRIT(fmt, args...) \
	do{ \
		if( SYS_LOG_CRIT > LOGLEVEL) break; \
		if( LOGTYPE & SYS_LOG_TYPE_FILE) LOGF_SYSLOG(LOG_CRIT, fmt, ##args); \
		if( LOGTYPE & SYS_LOG_TYPE_CONSOLE) LOGF_LOG_PRINT(COLOR_RED, "CRITICAL", fmt, ##args); \
	}while(0);

#define SYSLOG_ERR(fmt, args...) \
	do{ \
		if( SYS_LOG_ERR > LOGLEVEL) break; \
		if( LOGTYPE & SYS_LOG_TYPE_FILE) LOGF_SYSLOG(LOG_ERR, fmt, ##args); \
		if( LOGTYPE & SYS_LOG_TYPE_CONSOLE) LOGF_LOG_PRINT(COLOR_ORA, "ERROR", fmt, ##args); \
	}while(0);

#define SYSLOG_WARNING(fmt, args...) \
	do{ \
		if( SYS_LOG_WARNING > LOGLEVEL) break; \
		if( LOGTYPE & SYS_LOG_TYPE_FILE) LOGF_SYSLOG(LOG_WARNING, fmt, ##args); \
		if( LOGTYPE & SYS_LOG_TYPE_CONSOLE) LOGF_LOG_PRINT(COLOR_NRM, "WARNING", fmt, ##args); \
	}while(0);

#define SYSLOG_NOTICE(fmt, args...) \
	do{ \
		if( SYS_LOG_NOTICE > LOGLEVEL) break; \
		if( LOGTYPE & SYS_LOG_TYPE_FILE) LOGF_SYSLOG(LOG_NOTICE, fmt, ##args); \
		if( LOGTYPE & SYS_LOG_TYPE_CONSOLE) LOGF_LOG_PRINT(COLOR_NRM, "NOTICE", fmt, ##args); \
	}while(0);

#define SYSLOG_INFO(fmt, args...) \
	do{ \
		if( SYS_LOG_INFO > LOGLEVEL) break; \
		if( LOGTYPE & SYS_LOG_TYPE_FILE) LOGF_SYSLOG(LOG_INFO, fmt, ##args); \
		if( LOGTYPE & SYS_LOG_TYPE_CONSOLE) LOGF_LOG_PRINT(COLOR_GRN, "INFO", fmt, ##args); \
	}while(0);

#define SYSLOG_DEBUG(fmt, args...) \
	do{ \
		if( SYS_LOG_DEBUG > LOGLEVEL) break; \
		if( LOGTYPE & SYS_LOG_TYPE_FILE) LOGF_SYSLOG(LOG_DEBUG, fmt, ##args); \
		if( LOGTYPE & SYS_LOG_TYPE_CONSOLE) LOGF_LOG_PRINT(COLOR_BLU, "DEBUG", fmt, ##args); \
	}while(0);

#else /* USE_SYSLOG */

#define UGWLOG_PROFILE(fmt, args...) \
	do{ \
		if( UGW_LOG_PROFILE != LOGPROFILE) break; \
		LOGF_LOG_PRINT(COLOR_RED, "INFO", fmt, ##args); \
	}while(0);

#define SYSLOG_EMERG(fmt, args...) \
	do{ \
		if( SYS_LOG_EMERG > LOGLEVEL) break; \
		LOGF_LOG_PRINT(COLOR_RED, "EMERG", fmt, ##args); \
	}while(0);

#define SYSLOG_ALERT(fmt, args...) \
	do{ \
		if( SYS_LOG_ALERT > LOGLEVEL) break; \
		LOGF_LOG_PRINT(COLOR_RED, "ALERT", fmt, ##args); \
	}while(0);

#define SYSLOG_CRIT(fmt, args...) \
	do{ \
		if( SYS_LOG_CRIT > LOGLEVEL) break; \
		LOGF_LOG_PRINT(COLOR_RED, "CRITICAL", fmt, ##args); \
	}while(0);

#define SYSLOG_ERR(fmt, args...) \
	do{ \
		if( SYS_LOG_ERR > LOGLEVEL) break; \
		LOGF_LOG_PRINT(COLOR_ORA, "ERROR", fmt, ##args); \
	}while(0);

#define SYSLOG_WARNING(fmt, args...) \
	do{ \
		if( SYS_LOG_WARNING > LOGLEVEL) break; \
		LOGF_LOG_PRINT(COLOR_NRM, "WARNING", fmt, ##args); \
	}while(0);

#define SYSLOG_NOTICE(fmt, args...) \
	do{ \
		if( SYS_LOG_NOTICE > LOGLEVEL) break; \
		LOGF_LOG_PRINT(COLOR_NRM, "NOTICE", fmt, ##args); \
	}while(0);

#define SYSLOG_INFO(fmt, args...) \
	do{ \
		if( SYS_LOG_INFO > LOGLEVEL) break; \
		LOGF_LOG_PRINT(COLOR_NRM, "INFO", fmt, ##args); \
	}while(0);

#define SYSLOG_DEBUG(fmt, args...) \
	do{ \
		if( SYS_LOG_DEBUG > LOGLEVEL) break; \
		LOGF_LOG_PRINT(COLOR_NRM, "DEBUG", fmt, ##args); \
	}while(0);

#endif /* USE_SYSLOG */

#ifdef __cplusplus
}
#endif

#endif /* SPAL_LOGGING_H */
