{ pkgs }:
let
  qe3Revision = "7ed37274294c5dc47bda4cec601bb727be2875e0";
  ehsmRevision = "d87fb4884a32b9ecaecb5e7d45a25482344f21b3";
  sgxwalletRevision = "c24ad2580570064ce3dbc0a8a16122f67b081b32";
  signalCdsRevision = "69d33cfd8634fc3b1eb74b71e94cde77abe1a1c6";
in
{
  qe3 = pkgs.fetchFromGitHub {
    owner = "intel";
    repo = "confidential-computing.tee.dcap";
    rev = qe3Revision;
    hash = "sha256-GMZyiEoYK4xIxBbk+1ihL04o+CSKAFECfi4oL/8bnqw=";
    name = "qe3-${qe3Revision}";
  };
  ehsm = pkgs.fetchFromGitHub {
    owner = "intel";
    repo = "ehsm";
    rev = ehsmRevision;
    hash = "sha256-CMj9a8ilbOgvIgTKwSdbU+3x+226pdoCg0S2lEokXEw=";
    name = "ehsm-${ehsmRevision}";
  };
  sgxwallet = pkgs.fetchFromGitHub {
    owner = "skalenetwork";
    repo = "sgxwallet";
    rev = sgxwalletRevision;
    hash = "sha256-YF+EIK9hgEkeMEBGLu6uX1RRGrjDlVMJKry9Jfgu8tw=";
    name = "sgxwallet-${sgxwalletRevision}";
  };
  signalCds = pkgs.fetchFromGitHub {
    owner = "signalapp";
    repo = "ContactDiscoveryService";
    rev = signalCdsRevision;
    hash = "sha256-0Vo/+BBGbRBQgTQ2Z52+/srhRkDBFqcm5tYe6r9OBbU=";
    name = "signal-cds-${signalCdsRevision}";
  };
}
