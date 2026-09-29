// Fills in the "other" IP version (IPv4 if we arrived over IPv6, and vice versa) by
// querying the ip4./ip6. subdomain, and reports which protocol the page loaded over.
// Page-specific details come from data attributes on <body>, set by the templates:
//   data-theme               "standard" or "98"
//   data-base-domain         BASE_DOMAIN the app is configured with
//   data-version-subdomains  "false" when NO_IP_VERSION_SUBDOMAINS is set
function testOtherIpVersion() {
	const body = document.body;
	const theme = body.dataset.theme;
	const baseDomain = body.dataset.baseDomain;
	const hasVersionSubdomains = body.dataset.versionSubdomains !== "false";

	// find elements depending on template used
	let ipv4AddressElement, ipv6AddressElement, ipv4HostnameElement, ipv6HostnameElement;
	if (theme === "98") {
		ipv4AddressElement = document.querySelector('#ipv4-address');
		ipv6AddressElement = document.querySelector('#ipv6-address');
		ipv4HostnameElement = document.querySelector('#ipv4-hostname');
		ipv6HostnameElement = document.querySelector('#ipv6-hostname');
	} else {
		ipv4AddressElement = document.querySelector('td[data-ip-key="IPv4"]');
		ipv6AddressElement = document.querySelector('td[data-ip-key="IPv6"]');
		ipv4HostnameElement = document.querySelector('td[data-ip-key="HOSTNAME_IPv4"]');
		ipv6HostnameElement = document.querySelector('td[data-ip-key="HOSTNAME_IPv6"]');
	}

	// Determine the initial connection protocol
	let otherIpVersion;
	if (ipv4AddressElement && ipv4AddressElement.textContent.trim() === 'None') {
		otherIpVersion = 'ip4';
		document.getElementById('initial-protocol').textContent = 'IPv6';
	} else if (ipv6AddressElement && ipv6AddressElement.textContent.trim() === 'None') {
		otherIpVersion = 'ip6';
		document.getElementById('initial-protocol').textContent = 'IPv4';
	} else {
		// Neither IPv4 nor IPv6 is "None", so we can't determine the initial protocol
		return;
	}

	// Only the dual-stack host (ip.<BASE_DOMAIN>) can reach the other version's subdomain
	if (!hasVersionSubdomains || location.hostname !== `ip.${baseDomain}`) {
		return;
	}

	fetch(`${location.protocol}//${otherIpVersion}.${baseDomain}/json`)
		.then(response => {
			if (!response.ok) {
				throw new Error('Network response was not ok');
			}
			return response.json();
		})
		.then(data => {
			// Update the page with the retrieved IP information
			if (otherIpVersion === 'ip4') {
				if (ipv4AddressElement) ipv4AddressElement.textContent = data.IPv4;
				if (ipv4HostnameElement) ipv4HostnameElement.textContent = data.HOSTNAME_IPv4;
			} else {
				if (ipv6AddressElement) ipv6AddressElement.textContent = data.IPv6;
				if (ipv6HostnameElement) ipv6HostnameElement.textContent = data.HOSTNAME_IPv6;
			}
		})
		.catch(error => {
			console.error('Error fetching IP information:', error);
		});
}

window.addEventListener("load", testOtherIpVersion);
