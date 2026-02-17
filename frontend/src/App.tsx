import { BrowserRouter, Routes, Route } from 'react-router-dom';
import { AuthProvider } from './contexts/AuthContext';
import { ThemeProvider } from './contexts/ThemeContext';
import Navbar from './components/Navbar';
import ProtectedRoute from './components/ProtectedRoute';
import AdminRoute from './components/AdminRoute';
import LoginPage from './pages/LoginPage';
import DashboardPage from './pages/DashboardPage';
import StudentListPage from './pages/students/StudentListPage';
import StudentDetailPage from './pages/students/StudentDetailPage';
import StudentFormPage from './pages/students/StudentFormPage';
import DepartmentListPage from './pages/departments/DepartmentListPage';
import DepartmentDetailPage from './pages/departments/DepartmentDetailPage';
import DepartmentFormPage from './pages/departments/DepartmentFormPage';
import './App.css';

export default function App() {
  return (
    <BrowserRouter>
      <ThemeProvider>
        <AuthProvider>
          <Navbar />
          <main className="container">
            <Routes>
              <Route path="/login" element={<LoginPage />} />
              <Route
                path="/"
                element={
                  <ProtectedRoute>
                    <DashboardPage />
                  </ProtectedRoute>
                }
              />
              <Route
                path="/students"
                element={
                  <ProtectedRoute>
                    <StudentListPage />
                  </ProtectedRoute>
                }
              />
              <Route
                path="/students/new"
                element={
                  <ProtectedRoute>
                    <AdminRoute>
                      <StudentFormPage />
                    </AdminRoute>
                  </ProtectedRoute>
                }
              />
              <Route
                path="/students/:id"
                element={
                  <ProtectedRoute>
                    <StudentDetailPage />
                  </ProtectedRoute>
                }
              />
              <Route
                path="/students/:id/edit"
                element={
                  <ProtectedRoute>
                    <AdminRoute>
                      <StudentFormPage />
                    </AdminRoute>
                  </ProtectedRoute>
                }
              />
              <Route
                path="/departments"
                element={
                  <ProtectedRoute>
                    <DepartmentListPage />
                  </ProtectedRoute>
                }
              />
              <Route
                path="/departments/new"
                element={
                  <ProtectedRoute>
                    <AdminRoute>
                      <DepartmentFormPage />
                    </AdminRoute>
                  </ProtectedRoute>
                }
              />
              <Route
                path="/departments/:id"
                element={
                  <ProtectedRoute>
                    <DepartmentDetailPage />
                  </ProtectedRoute>
                }
              />
              <Route
                path="/departments/:id/edit"
                element={
                  <ProtectedRoute>
                    <AdminRoute>
                      <DepartmentFormPage />
                    </AdminRoute>
                  </ProtectedRoute>
                }
              />
            </Routes>
          </main>
        </AuthProvider>
      </ThemeProvider>
    </BrowserRouter>
  );
}
