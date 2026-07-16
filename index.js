fetch("VERSION.txt")
  .then(response => response.text())
  .then(version => {
    document.getElementById("version").textContent = `v${version.trim()}`;
  })
  .catch(error => console.error(error));