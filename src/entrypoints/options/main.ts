import { mount } from 'svelte';
import App from './App.svelte';
import '@fontsource-variable/geist/wght.css';
import '@/assets/theme.css';
import '@/assets/ui.css';
import './app.css';
import { applyTheme } from '@/lib/theme';

applyTheme();
mount(App, { target: document.getElementById('app')! });
