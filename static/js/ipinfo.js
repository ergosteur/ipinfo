function testOtherIpVersion() {
	let otherIpVersion;
	var currentUrl = window.location.href;
	console.log("Running ipinfo.js");
	
	// find elements depending on template used
    if (currentUrl.includes("98")) {
		console.log("We are running on Windows 98");
		var ipv4AddressElement = document.querySelector('#ipv4-address');
		var ipv6AddressElement = document.querySelector('#ipv6-address');
		var ipv4HostnameElement = document.querySelector('#ipv4-hostname');
		var ipv6HostnameElement = document.querySelector('#ipv6-hostname');
	} else {
		console.log("Base template");
		var ipv4AddressElement = document.querySelector('td[data-ip-key="IPv4"]');
		var ipv6AddressElement = document.querySelector('td[data-ip-key="IPv6"]');
		var ipv4HostnameElement = document.querySelector('td[data-ip-key="HOSTNAME_IPv4"]');
		var ipv6HostnameElement = document.querySelector('td[data-ip-key="HOSTNAME_IPv6"]');
	}
	// Determine the initial connection protocol
	if (ipv4AddressElement && ipv4AddressElement.textContent === 'None') {
		otherIpVersion = 'ip4';
		document.getElementById('initial-protocol').textContent = 'IPv6';
    } else if (ipv6AddressElement && ipv6AddressElement.textContent === 'None') {
		otherIpVersion = 'ip6';
		document.getElementById('initial-protocol').textContent = 'IPv4';
    } else {
		// Neither IPv4 nor IPv6 is "None", so we can't determine the initial protocol
		return;
    }
  // Only test the other IP version if the current URL is ip.1qaz.ca
  if (currentUrl.includes("ip.")) {
	console.log("dual-stack mode")  

    // Extract the root domain using the provided logic
    var rootDomain = location.hostname.split('.').reverse().splice(0, 2).reverse().join('.');

    // varruct the otherUrl
    var otherUrl = `https://${otherIpVersion}.${rootDomain}/json`;

    fetch(otherUrl)
      .then(response => {
        if (!response.ok) {
          throw new Error('Network response was not ok');
        }
        return response.json();
      })
      .then(data => {
        // Update the page with the retrieved IP information
        if (otherIpVersion === 'ip4') {
          // Find the IPv4 address and hostname elements and update them
          if (ipv4AddressElement) ipv4AddressElement.textContent = data.IPv4;
          if (ipv4HostnameElement) ipv4HostnameElement.textContent = data.HOSTNAME_IPv4;
        } else {
          // Find the IPv6 address and hostname elements and update them
          if (ipv6AddressElement) ipv6AddressElement.textContent = data.IPv6;
          if (ipv6HostnameElement) ipv6HostnameElement.textContent = data.HOSTNAME_IPv6;
        }
      })
      .catch(error => {
        console.error('Error fetching IP information:', error);
        // Optionally display an error message to the user
      });
  } else if (currentUrl.includes("ip6.") || currentUrl.includes("ipv6.")) {
	  console.log("IPv6 mode");
  }
	  
}

// run the function on load
//window.onload = testOtherIpVersion()
window.addEventListener("load", (event) => {
  console.log("page is fully loaded");
  testOtherIpVersion();
});