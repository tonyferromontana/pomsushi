/**
 * RUÉ · Sistema de diseño (tokens).
 * Única fuente de colores, tipografías, espaciados y radios.
 * Ningún componente debe escribir un color, fuente o tamaño suelto.
 */

// -----------------------------------------------------------------------------
// Paleta de marca
// -----------------------------------------------------------------------------
export const palette = {
  asphalt: '#101114',
  carbon: '#181A1F',
  carbonRaised: '#202329',
  line: '#2A2D34',
  graphite: '#868A93',
  bone: '#F5F3EE',
  lime: '#D7FF3F',
  limePressed: '#C3EB2B',
  black: '#000000',
  green: '#4ADE80',
  amber: '#F5B544',
  red: '#FF6B5E',
  blue: '#7CB7FF',
} as const;

// -----------------------------------------------------------------------------
// Colores semánticos (usar estos en componentes, no `palette`)
// -----------------------------------------------------------------------------
export const colors = {
  background: palette.asphalt,
  surface: palette.carbon,
  surfaceRaised: palette.carbonRaised,
  border: palette.line,
  text: palette.bone,
  textSecondary: palette.graphite,
  textInverse: palette.asphalt,
  accent: palette.lime,
  accentPressed: palette.limePressed,
  onAccent: palette.asphalt,
  success: palette.green,
  warning: palette.amber,
  error: palette.red,
  info: palette.blue,
  disabled: palette.line,
  onDisabled: palette.graphite,
  overlay: 'rgba(0,0,0,0.6)',
  scrim: 'rgba(16,17,20,0.72)',
} as const;

export type ColorToken = keyof typeof colors;

// -----------------------------------------------------------------------------
// Tipografía
// Bricolage Grotesque → marca, títulos, números y precios.
// DM Sans → interfaz, formularios, textos.
// -----------------------------------------------------------------------------
export const fonts = {
  display: 'BricolageGrotesque_700Bold',
  displaySemi: 'BricolageGrotesque_600SemiBold',
  body: 'DMSans_400Regular',
  bodyMedium: 'DMSans_500Medium',
  bodySemi: 'DMSans_600SemiBold',
} as const;

export const type = {
  display: { fontFamily: fonts.display, fontSize: 40, lineHeight: 44, letterSpacing: -1 },
  h1: { fontFamily: fonts.display, fontSize: 30, lineHeight: 36, letterSpacing: -0.6 },
  h2: { fontFamily: fonts.display, fontSize: 24, lineHeight: 30, letterSpacing: -0.4 },
  h3: { fontFamily: fonts.displaySemi, fontSize: 19, lineHeight: 24, letterSpacing: -0.2 },
  title: { fontFamily: fonts.bodySemi, fontSize: 16, lineHeight: 22 },
  body: { fontFamily: fonts.body, fontSize: 16, lineHeight: 23 },
  bodySmall: { fontFamily: fonts.body, fontSize: 14, lineHeight: 20 },
  label: { fontFamily: fonts.bodyMedium, fontSize: 14, lineHeight: 18 },
  caption: { fontFamily: fonts.body, fontSize: 12, lineHeight: 16 },
  overline: { fontFamily: fonts.bodySemi, fontSize: 11, lineHeight: 14, letterSpacing: 1.2 },
  price: { fontFamily: fonts.display, fontSize: 18, lineHeight: 22, letterSpacing: -0.2 },
  priceLarge: { fontFamily: fonts.display, fontSize: 32, lineHeight: 36, letterSpacing: -0.8 },
} as const;

export type TypeVariant = keyof typeof type;

// -----------------------------------------------------------------------------
// Espaciado, radios, tamaños
// -----------------------------------------------------------------------------
export const space = {
  xxs: 2,
  xs: 4,
  sm: 8,
  md: 12,
  lg: 16,
  xl: 24,
  xxl: 32,
  xxxl: 48,
} as const;

/** Margen lateral estándar de pantalla */
export const gutter = space.xl;

export const radius = {
  sm: 8,
  md: 12,
  lg: 18,
  xl: 24,
  pill: 999,
} as const;

export const size = {
  control: 52,
  controlSmall: 36,
  icon: 22,
  avatar: 40,
  hairline: 1,
} as const;

/** Proporción estándar de fotos de vehículos (ancho / alto) */
export const photoAspect = 4 / 3;
