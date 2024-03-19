/*
 * Copyright 2024 Vsevolod Stakhov
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *    http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#ifndef UPSTREAM_H
#define UPSTREAM_H

#include "config.h"
#include "util.h"
#include "rdns.h"
#include "ucl.h"

#ifdef __cplusplus
extern "C" {
#endif

/* Forward declaration */
struct ev_loop;

enum rspamd_upstream_rotation {
	RSPAMD_UPSTREAM_RANDOM = 0,
	RSPAMD_UPSTREAM_HASHED,
	RSPAMD_UPSTREAM_ROUND_ROBIN,
	RSPAMD_UPSTREAM_MASTER_SLAVE,
	RSPAMD_UPSTREAM_SEQUENTIAL,
	RSPAMD_UPSTREAM_UNDEF
};

enum rspamd_upstream_flag {
	RSPAMD_UPSTREAM_FLAG_NORESOLVE = (1 << 0),
	RSPAMD_UPSTREAM_FLAG_SRV_RESOLVE = (1 << 1),
};

struct rspamd_config;
/* Opaque upstream structures */
struct upstream;
struct upstream_list;
struct upstream_ctx;

/**
 * Init upstreams library
 * @param resolver
 */
struct upstream_ctx *rspamd_upstreams_library_init(void);

/**
 * Remove reference from upstreams library
 */
void rspamd_upstreams_library_unref(struct upstream_ctx *ctx);

/**
 * Configure attributes of upstreams library
 * @param cfg
 */
void rspamd_upstreams_library_config(struct rspamd_config *cfg,
									 struct upstream_ctx *ctx, struct ev_loop *event_loop,
									 struct rdns_resolver *resolver);

/**
 * Upstream error logic
 * 1. During error time we count upstream_ok and upstream_fail
 * 2. If failcount is more then maxerrors then we mark upstream as unavailable for dead time
 * 3. After dead time we mark upstream as alive and go to the step 1
 * 4. If all upstreams are dead, marks every upstream as alive
 */

/**
 * Add an error to an upstream
 */
void rspamd_upstream_fail(struct upstream *upstream, gboolean addr_failure, const char *reason);

/**
 * Increase upstream successes count
 */
void rspamd_upstream_ok(struct upstream *up);

/**
 * Set weight for an upstream
 * @param up
 */
void rspamd_upstream_set_weight(struct upstream *up, unsigned int weight);

/**
 * Create new list of upstreams
 * @return
 */
struct upstream_list *rspamd_upstreams_create(struct upstream_ctx *ctx);

/**
 * Sets specific flag to the upstream list
 * @param ups
 * @param flags
 */
void rspamd_upstreams_set_flags(struct upstream_list *ups,
								enum rspamd_upstream_flag flags);

/**
 * Sets custom limits for upstreams
 * This function allocates memory from the upstreams ctx pool and should
 * not be called in cycles/constantly as this memory is likely persistent
 * @param ups
 * @param revive_time
 * @param revive_jitter
 * @param error_time
 * @param dns_timeout
 * @param max_errors
 * @param dns_retransmits
 */
void rspamd_upstreams_set_limits(struct upstream_list *ups,
								 double revive_time,
								 double revive_jitter,
								 double error_time,
								 double dns_timeout,
								 unsigned int max_errors,
								 unsigned int dns_retransmits);

/**
 * Sets rotation policy for upstreams list
 * @param ups
 * @param rot
 */
void rspamd_upstreams_set_rotation(struct upstream_list *ups,
								   enum rspamd_upstream_rotation rot);

/**
 * Destroy list of upstreams
 * @param ups
 */
void rspamd_upstreams_destroy(struct upstream_list *ups);

/**
 * Returns count of upstreams in a list
 * @param ups
 * @return
 */
gsize rspamd_upstreams_count(struct upstream_list *ups);

/**
 * Returns the number of upstreams in the list
 * @param ups
 * @return
 */
gsize rspamd_upstreams_alive(struct upstream_list *ups);

enum rspamd_upstream_parse_type {
	RSPAMD_UPSTREAM_PARSE_DEFAULT = 0,
	RSPAMD_UPSTREAM_PARSE_NAMESERVER,
};

/**
 * Add upstream from the string
 * @param ups upstream list
 * @param str string in format "name[:port[:priority]]"
 * @param def_port default port number
 * @param data optional userdata
 * @return TRUE if upstream has been added
 */
gboolean rspamd_upstreams_add_upstream(struct upstream_list *ups, const char *str,
									   uint16_t def_port, enum rspamd_upstream_parse_type parse_type,
									   void *data);

/**
 * Add multiple upstreams from comma, semicolon or space separated line
 * @param ups upstream list
 * @param str string in format "(<ups>([<sep>+]<ups>)*)+"
 * @param def_port default port number
 * @param data optional userdata
 * @return TRUE if **any** of upstreams has been added
 */
gboolean rspamd_upstreams_parse_line(struct upstream_list *ups,
									 const char *str, uint16_t def_port, void *data);


gboolean rspamd_upstreams_parse_line_len(struct upstream_list *ups,
										 const char *str, gsize len,
										 uint16_t def_port,
										 void *data);

/**
 * Parse upstreams list from the UCL object
 * @param ups
 * @param in
 * @param def_port
 * @param data
 * @return
 */
gboolean rspamd_upstreams_from_ucl(struct upstream_list *ups,
								   const ucl_object_t *in, uint16_t def_port, void *data);


typedef void (*rspamd_upstream_traverse_func)(struct upstream *up, unsigned int idx,
											  void *ud);

/**
 * Traverse upstreams list calling the function specified
 * @param ups
 * @param cb
 * @param ud
 */
void rspamd_upstreams_foreach(struct upstream_list *ups,
							  rspamd_upstream_traverse_func cb, void *ud);

enum rspamd_upstreams_watch_event {
	RSPAMD_UPSTREAM_WATCH_SUCCESS = 1u << 0,
	RSPAMD_UPSTREAM_WATCH_FAILURE = 1u << 1,
	RSPAMD_UPSTREAM_WATCH_OFFLINE = 1u << 2,
	RSPAMD_UPSTREAM_WATCH_ONLINE = 1u << 3,
	RSPAMD_UPSTREAM_WATCH_ALL = (1u << 0) | (1u << 1) | (1u << 2) | (1u << 3),
};

typedef void (*rspamd_upstream_watch_func)(struct upstream *up,
										   enum rspamd_upstreams_watch_event event,
										   unsigned int cur_errors,
										   void *ud);

/**
 * Adds new watcher to the upstreams list
 * @param ups
 * @param events
 * @param func
 * @param ud
 */
void rspamd_upstreams_add_watch_callback(struct upstream_list *ups,
										 enum rspamd_upstreams_watch_event events,
										 rspamd_upstream_watch_func func,
										 GFreeFunc free_func,
										 gpointer ud);

/**
 * Returns the next IP address of the upstream (internal rotation)
 * @param up
 * @return
 */
rspamd_inet_addr_t *rspamd_upstream_addr_next(struct upstream *up);

/**
 * Returns the current IP address of the upstream
 * @param up
 * @return
 */
rspamd_inet_addr_t *rspamd_upstream_addr_cur(const struct upstream *up);

/**
 * Add custom address for an upstream (ownership of addr is transferred to upstream)
 * @param up
 * @return
 */
gboolean rspamd_upstream_add_addr(struct upstream *up,
								  rspamd_inet_addr_t *addr);

/**
 * Returns the symbolic name of the upstream
 * @param up
 * @return
 */
const char *rspamd_upstream_name(struct upstream *up);

/**
 * Returns the port of the current address for the upstream
 * @param up
 * @return
 */
int rspamd_upstream_port(struct upstream *up);

/**
 * Sets opaque user data associated with this upstream
 * @param up
 * @param data
 * @return old data
 */
gpointer rspamd_upstream_set_data(struct upstream *up, gpointer data);

/**
 * Gets opaque user data associated with this upstream
 * @param up
 * @return
 */
gpointer rspamd_upstream_get_data(struct upstream *up);

/**
 * Get new upstream from the list
 * @param ups upstream list
 * @param type type of rotation algorithm, for `RSPAMD_UPSTREAM_HASHED` it is required to specify `key` and `keylen` as arguments
 * @return
 */
struct upstream *rspamd_upstream_get(struct upstream_list *ups,
									 enum rspamd_upstream_rotation default_type,
									 const unsigned char *key, gsize keylen);

/**
 * Get new upstream from the list
 * @param ups upstream list
 * @param type type of rotation algorithm, for `RSPAMD_UPSTREAM_HASHED` it is required to specify `key` and `keylen` as arguments
 * @return
 */
struct upstream *rspamd_upstream_get_forced(struct upstream_list *ups,
											enum rspamd_upstream_rotation forced_type,
											const unsigned char *key, gsize keylen);

/**
 * Get new upstream from the list excepting the upstream specified
 * @param ups upstream list
 * @param type type of rotation algorithm, for `RSPAMD_UPSTREAM_HASHED` it is required to specify `key` and `keylen` as arguments
 * @return
 */
struct upstream *rspamd_upstream_get_except(struct upstream_list *ups,
											struct upstream *except,
											enum rspamd_upstream_rotation default_type,
											const unsigned char *key, gsize keylen);

/**
 * Re-resolve addresses for all upstreams registered
 */
void rspamd_upstream_reresolve(struct upstream_ctx *ctx);

/**
 * Share ownership on upstream
 * @param up
 * @return
 */
struct upstream *rspamd_upstream_ref(struct upstream *up);
/**
 * Unshare ownership on upstream
 * @param up
 */
void rspamd_upstream_unref(struct upstream *up);

#ifdef __cplusplus
}
#endif

#endif /* UPSTREAM_H */
