# Hackorum Stylesheet Architecture

This directory contains the organized, modular CSS for the Hackorum application.

## Structure

```
app/assets/stylesheets/
├── application.css              # Main manifest (imports all files)
├── variables.css                # Design system tokens
├── base/
│   └── reset.css               # CSS reset and base styles
├── components/
│   ├── avatars.css             # User avatar styles
│   ├── messages.css            # Message display and threading
│   ├── navigation.css          # Main navigation bar
│   ├── search.css              # Search form and results
│   └── topics.css              # Topic list table
└── layouts/
    ├── header.css              # Page header sections
    ├── responsive.css          # Mobile/tablet responsive styles
    └── topic-view.css          # Topic detail page layout
```

## Design System

### Variables (`variables.css`)

All design tokens are defined as CSS custom properties in `variables.css`:

- **Colors**: Semantic color palette (primary, grays, accents)
- **Spacing**: Consistent spacing scale (1-12)
- **Typography**: Font families, sizes, weights, line heights
- **Borders**: Widths, radii
- **Shadows**: Elevation levels
- **Transitions**: Animation timings
- **Layout**: Container widths, component sizes

### Modern CSS Features

This codebase uses modern, native CSS features:

- **CSS Custom Properties** (CSS Variables) for theming
- **Native CSS Nesting** for cleaner, more maintainable code
- **@import** for modular file organization

All features are supported natively in modern browsers (2024+).

## Modifying Styles

### Changing Colors

Edit `variables.css` to change the color palette. All colors are centralized here:

```css
:root {
  --color-primary-600: #1e40af;  /* Change primary color */
  --color-text-primary: #1e293b; /* Change text color */
}
```

### Adding New Components

1. Create a new file in `components/` (e.g., `components/comments.css`)
2. Add component-specific styles using nesting
3. Import it in `application.css`

Example:
```css
/* components/comments.css */
.comment {
  background: var(--color-bg-card);
  padding: var(--spacing-4);

  & .comment-author {
    font-weight: var(--font-weight-semibold);
    color: var(--color-text-primary);
  }

  &:hover {
    background: var(--color-bg-hover);
  }
}
```

### Responsive Design

Mobile-specific overrides are in `layouts/responsive.css`. The breakpoint is:

- **Mobile**: `max-width: 768px`

## Best Practices

1. **Use CSS Variables**: Always use variables from `variables.css`, never hardcode values
2. **Component Organization**: Keep component styles in their own files
3. **Nesting**: Use native CSS nesting for clarity, but don't nest more than 3 levels deep
4. **Naming**: Use semantic class names that describe purpose, not appearance
5. **Specificity**: Keep specificity low - prefer classes over IDs or complex selectors

## File Loading Order

The order in `application.css` matters:

1. **Variables** - Must load first (other files reference them)
2. **Base** - Foundation styles
3. **Layouts** - Page structure
4. **Components** - Reusable UI elements
5. **Responsive** - Must load last (overrides desktop styles)

## Asset Pipeline

This app uses **Propshaft** (Rails 8 default):

- No preprocessing/compilation needed
- Files are served directly with fingerprinting
- `@import` statements are resolved by the browser
- Native CSS features work out of the box

## Migration from Old Structure

The previous 700-line `application.css` has been split into:

- **11 modular files** organized by purpose
- **All hardcoded colors** replaced with CSS variables
- **Modern CSS nesting** for better readability
- **Clear separation of concerns** (components vs layouts)

No functionality was changed - only organization and maintainability improved.
