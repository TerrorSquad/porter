//! Shared small types used across cli/chunker/renderer.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EccLevel {
    L,
    M,
    Q,
    H,
}

impl EccLevel {
    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "L" => Some(EccLevel::L),
            "M" => Some(EccLevel::M),
            "Q" => Some(EccLevel::Q),
            "H" => Some(EccLevel::H),
            _ => None,
        }
    }

    pub fn to_qrcode_ec_level(self) -> qrcode::EcLevel {
        match self {
            EccLevel::L => qrcode::EcLevel::L,
            EccLevel::M => qrcode::EcLevel::M,
            EccLevel::Q => qrcode::EcLevel::Q,
            EccLevel::H => qrcode::EcLevel::H,
        }
    }
}

impl std::fmt::Display for EccLevel {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let s = match self {
            EccLevel::L => "L",
            EccLevel::M => "M",
            EccLevel::Q => "Q",
            EccLevel::H => "H",
        };
        write!(f, "{s}")
    }
}
