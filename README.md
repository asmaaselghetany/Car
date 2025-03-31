# TUM BPM Car Navigation Process

This project implements a car navigation process with real-time visualization as part of the BPM course at TUM.

## Project Structure
```
.
├── car-navigation-process.xml    # CPEE process model
├── src/
│   ├── backend/                 # Backend service
│   │   └── car_service.rb       # Main Ruby service
│   └── frontend/               # Frontend visualization
│       └── frontend_car_dashboard.html
└── README.md
```

## Features
- Real-time car position tracking
- Traffic and weather data integration
- Interactive map visualization
- Process instance monitoring
- Data analysis and statistics

## API Integration
The system integrates with:
- TomTom API for navigation and traffic data
- OpenWeather API for weather conditions

## Development Structure
- `car-navigation-process.xml`: Defines the CPEE process model
- `car_service.rb`: Implements the backend service with API integrations
- `frontend_car_dashboard.html`: Provides the visualization interface

## Server Information
- Server: lehre.bpm.in.tum.de
- Backend Port: 15000
- Frontend Path: /~ge74tar/car_dashboard/index.html
- Process Data Storage: /home/ge74tar/data/
- CPEE URL: https://cpee.org/hub/?stage=development&dir=Teaching.dir/Prak.dir/TUM-Prak-24-WS.dir/Asmaa%20Elghitany.dir/

## Contact
For questions or issues, please contact:
Asmaa Elghitany (asmaaselghetany@gmail.com)
