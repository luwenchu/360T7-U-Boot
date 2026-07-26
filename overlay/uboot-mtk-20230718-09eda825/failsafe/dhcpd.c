// SPDX-License-Identifier: GPL-2.0-only
/*
 * Minimal DHCPv4 server for the MediaTek Web failsafe environment.
 *
 * This is intentionally limited to a temporary recovery LAN. It does not
 * persist leases, route packets, or run outside the MTK TCP failsafe loop.
 */

#include <common.h>
#include <net.h>
#include <linux/types.h>

#include "dhcpd.h"

#define DHCPD_SERVER_PORT	67
#define DHCPD_CLIENT_PORT	68
#define DHCPD_MAGIC_SIZE	4
#define DHCPD_OPTIONS_SIZE	64
#define DHCPD_MAX_LEASES	8
#define DHCPD_POOL_FIRST	100
#define DHCPD_POOL_LAST		199
#define DHCPD_LEASE_SECONDS	3600

#define DHCP_BOOTREQUEST	1
#define DHCP_BOOTREPLY		2
#define DHCP_HTYPE_ETHERNET	1
#define DHCP_HLEN_ETHERNET	6

#define DHCP_OPT_PAD		0
#define DHCP_OPT_SUBNET_MASK	1
#define DHCP_OPT_ROUTER		3
#define DHCP_OPT_DNS		6
#define DHCP_OPT_REQUESTED_IP	50
#define DHCP_OPT_LEASE_TIME	51
#define DHCP_OPT_MSG_TYPE	53
#define DHCP_OPT_SERVER_ID	54
#define DHCP_OPT_BROADCAST	28
#define DHCP_OPT_END		255

#define DHCP_DISCOVER		1
#define DHCP_OFFER		2
#define DHCP_REQUEST		3
#define DHCP_DECLINE		4
#define DHCP_ACK		5
#define DHCP_NAK		6
#define DHCP_RELEASE		7

static const u8 dhcp_magic[DHCPD_MAGIC_SIZE] = { 0x63, 0x82, 0x53, 0x63 };

struct dhcpd_packet {
	u8 op;
	u8 htype;
	u8 hlen;
	u8 hops;
	u32 xid;
	u16 secs;
	u16 flags;
	struct in_addr ciaddr;
	struct in_addr yiaddr;
	struct in_addr siaddr;
	struct in_addr giaddr;
	u8 chaddr[16];
	u8 sname[64];
	u8 file[128];
	u8 options[DHCPD_OPTIONS_SIZE];
} __packed;

struct dhcpd_lease {
	u8 mac[DHCP_HLEN_ETHERNET];
	u8 host;
	bool used;
};

static struct dhcpd_lease leases[DHCPD_MAX_LEASES];
static u8 next_host = DHCPD_POOL_FIRST;
static bool dhcpd_enabled;

static const u8 *dhcpd_find_option(const u8 *options, size_t len, u8 code,
				   u8 *option_len)
{
	size_t pos = DHCPD_MAGIC_SIZE;

	if (len < DHCPD_MAGIC_SIZE ||
	    memcmp(options, dhcp_magic, DHCPD_MAGIC_SIZE))
		return NULL;

	while (pos < len) {
		u8 current = options[pos++];
		u8 current_len;

		if (current == DHCP_OPT_PAD)
			continue;
		if (current == DHCP_OPT_END)
			break;
		if (pos >= len)
			break;

		current_len = options[pos++];
		if (current_len > len - pos)
			break;
		if (current == code) {
			*option_len = current_len;
			return &options[pos];
		}
		pos += current_len;
	}

	return NULL;
}

static struct in_addr dhcpd_ip_for_client(const u8 *mac)
{
	struct in_addr address = string_to_ip("192.168.1.100");
	int free_slot = -1;
	int i;
	u8 host;

	for (i = 0; i < DHCPD_MAX_LEASES; i++) {
		if (leases[i].used &&
		    !memcmp(leases[i].mac, mac, DHCP_HLEN_ETHERNET)) {
			host = leases[i].host;
			goto found;
		}
		if (!leases[i].used && free_slot < 0)
			free_slot = i;
	}

	host = next_host++;
	if (next_host > DHCPD_POOL_LAST)
		next_host = DHCPD_POOL_FIRST;

	if (free_slot >= 0) {
		memcpy(leases[free_slot].mac, mac, DHCP_HLEN_ETHERNET);
		leases[free_slot].host = host;
		leases[free_slot].used = true;
	} else {
		host = DHCPD_POOL_FIRST +
		       (mac[DHCP_HLEN_ETHERNET - 1] %
			(DHCPD_POOL_LAST - DHCPD_POOL_FIRST + 1));
	}

found:
	((u8 *)&address.s_addr)[3] = host;
	return address;
}

static u8 *dhcpd_add_option(u8 *p, u8 code, const void *data, u8 len)
{
	*p++ = code;
	*p++ = len;
	memcpy(p, data, len);
	return p + len;
}

static void dhcpd_send_reply(const struct dhcpd_packet *request, u8 msg_type,
			     struct in_addr offered_ip)
{
	struct dhcpd_packet *reply;
	struct in_addr broadcast = string_to_ip("255.255.255.255");
	struct in_addr subnet = string_to_ip("255.255.255.0");
	struct in_addr lan_broadcast = string_to_ip("192.168.1.255");
	u32 lease_time = htonl(DHCPD_LEASE_SECONDS);
	u8 *option;
	size_t payload_len;

	reply = (struct dhcpd_packet *)(net_tx_packet + net_eth_hdr_size() +
				       IP_UDP_HDR_SIZE);
	memset(reply, 0, sizeof(*reply));

	reply->op = DHCP_BOOTREPLY;
	reply->htype = DHCP_HTYPE_ETHERNET;
	reply->hlen = DHCP_HLEN_ETHERNET;
	reply->xid = request->xid;
	reply->flags = request->flags;
	reply->yiaddr = offered_ip;
	reply->siaddr = net_ip;
	memcpy(reply->chaddr, request->chaddr, sizeof(reply->chaddr));

	option = reply->options;
	memcpy(option, dhcp_magic, sizeof(dhcp_magic));
	option += sizeof(dhcp_magic);
	option = dhcpd_add_option(option, DHCP_OPT_MSG_TYPE, &msg_type,
				  sizeof(msg_type));
	option = dhcpd_add_option(option, DHCP_OPT_SERVER_ID, &net_ip.s_addr,
				  sizeof(net_ip.s_addr));

	if (msg_type != DHCP_NAK) {
		option = dhcpd_add_option(option, DHCP_OPT_SUBNET_MASK,
					  &subnet.s_addr,
					  sizeof(subnet.s_addr));
		option = dhcpd_add_option(option, DHCP_OPT_ROUTER,
					  &net_ip.s_addr,
					  sizeof(net_ip.s_addr));
		option = dhcpd_add_option(option, DHCP_OPT_DNS,
					  &net_ip.s_addr,
					  sizeof(net_ip.s_addr));
		option = dhcpd_add_option(option, DHCP_OPT_BROADCAST,
					  &lan_broadcast.s_addr,
					  sizeof(lan_broadcast.s_addr));
		option = dhcpd_add_option(option, DHCP_OPT_LEASE_TIME,
					  &lease_time, sizeof(lease_time));
	}
	*option++ = DHCP_OPT_END;

	payload_len = sizeof(*reply) - sizeof(reply->options) +
		      (option - reply->options);
	if (payload_len < sizeof(*reply))
		payload_len = sizeof(*reply);

	net_send_udp_packet((uchar *)net_bcast_ethaddr, broadcast,
			    DHCPD_CLIENT_PORT, DHCPD_SERVER_PORT, payload_len);
}

static void dhcpd_handler(uchar *pkt, unsigned dport, struct in_addr sip,
			  unsigned sport, unsigned len)
{
	const struct dhcpd_packet *request = (const void *)pkt;
	const u8 *value;
	struct in_addr offered_ip;
	struct in_addr requested_ip = { 0 };
	struct in_addr server_id = { 0 };
	size_t options_offset = offsetof(struct dhcpd_packet, options);
	u8 value_len;
	u8 msg_type;

	(void)sip;

	if (!dhcpd_enabled || dport != DHCPD_SERVER_PORT ||
	    sport != DHCPD_CLIENT_PORT || len < options_offset + DHCPD_MAGIC_SIZE)
		return;
	if (request->op != DHCP_BOOTREQUEST ||
	    request->htype != DHCP_HTYPE_ETHERNET ||
	    request->hlen != DHCP_HLEN_ETHERNET)
		return;

	value = dhcpd_find_option(request->options, len - options_offset,
				  DHCP_OPT_MSG_TYPE, &value_len);
	if (!value || value_len != 1)
		return;
	msg_type = value[0];

	if (msg_type == DHCP_DECLINE || msg_type == DHCP_RELEASE)
		return;
	if (msg_type != DHCP_DISCOVER && msg_type != DHCP_REQUEST)
		return;

	offered_ip = dhcpd_ip_for_client(request->chaddr);
	if (msg_type == DHCP_DISCOVER) {
		dhcpd_send_reply(request, DHCP_OFFER, offered_ip);
		printf("DHCP: offered %pI4 to %pM\n", &offered_ip,
		       request->chaddr);
		return;
	}

	value = dhcpd_find_option(request->options, len - options_offset,
				  DHCP_OPT_SERVER_ID, &value_len);
	if (value && value_len == sizeof(server_id.s_addr)) {
		memcpy(&server_id.s_addr, value, sizeof(server_id.s_addr));
		if (server_id.s_addr != net_ip.s_addr)
			return;
	}

	value = dhcpd_find_option(request->options, len - options_offset,
				  DHCP_OPT_REQUESTED_IP, &value_len);
	if (value && value_len == sizeof(requested_ip.s_addr))
		memcpy(&requested_ip.s_addr, value, sizeof(requested_ip.s_addr));
	else
		requested_ip = request->ciaddr;

	if (requested_ip.s_addr && requested_ip.s_addr != offered_ip.s_addr) {
		struct in_addr empty_ip = { 0 };

		dhcpd_send_reply(request, DHCP_NAK, empty_ip);
		printf("DHCP: rejected request from %pM\n", request->chaddr);
		return;
	}

	dhcpd_send_reply(request, DHCP_ACK, offered_ip);
	printf("DHCP: leased %pI4 to %pM\n", &offered_ip, request->chaddr);
}

void failsafe_dhcpd_start(void)
{
	memset(leases, 0, sizeof(leases));
	next_host = DHCPD_POOL_FIRST;
	dhcpd_enabled = true;
	printf("DHCP server: 192.168.1.100-192.168.1.199\n");
}

void failsafe_dhcpd_stop(void)
{
	if (net_get_udp_handler() == dhcpd_handler)
		net_set_udp_handler(NULL);
	dhcpd_enabled = false;
}

void mtk_tcp_start_hook(void)
{
	if (dhcpd_enabled)
		net_set_udp_handler(dhcpd_handler);
}
